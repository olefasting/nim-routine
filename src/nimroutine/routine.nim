import os, locks, lists, tables, macros

const debug = true
proc print[T](data: T) =
  when debug:
    echo data

# Thread
type
  BreakState = object
    isContinue: bool # tell whether this yield need to be continued later
    isSend: bool  # this yield is caused by a send operation
    msgBoxPtr: pointer # this msgBox's pointer (void*) that makes this yield

  TaskBody = (iterator(tl: TaskList, t: ptr Task, arg:pointer): BreakState{.closure.})
  Task = object
    isRunable: bool # if the task is runnable
    task: TaskBody
    arg: pointer

  TaskList = ptr TaskListObj
  TaskListObj = object
    lock: Lock # Protect list
    candiLock: Lock # Protect send and recv candidate
    list: DoublyLinkedRing[Task]
    size: int # list's size
    recvWaiter: Table[pointer, seq[ptr Task]]
    sendWaiter: Table[pointer, seq[ptr Task]]
    sendCandidate: seq[pointer]
    recvCandidate: seq[pointer]

const threadPoolSize = 4.Natural
var taskListPool = newSeq[TaskListObj](threadPoolSize)
var threadPool= newSeq[Thread[TaskList]](threadPoolSize)

proc isEmpty(tasks: TaskList): bool=
  result = tasks.list.head == nil

proc run(taskNode: DoublyLinkedNode[Task], tasks: TaskList, t: ptr Task): BreakState {.inline.} =
  result = taskNode.value.task(tasks, t, t.arg)

# Run a task, return false if no runnable task found
proc runTask(tasks: TaskList, tracker: var DoublyLinkedNode[Task]): bool {.gcsafe.} =
  if tracker == nil: tracker = tasks.list.head
  let start = tracker

  while not tasks.isEmpty:
    if tracker.value.isRunable:
      tasks.lock.release()
      let ret = tracker.run(tasks, tracker.value.addr)
      tasks.lock.acquire()

      if not ret.isContinue:
        #print("one task finished")
        let temp = tracker.next
        tracker.value.arg.deallocShared() # free task argument
        tasks.list.remove(tracker)
        tasks.size -= 1 
        if tasks.isEmpty:
          #print("tasks is empty")
          tracker = nil
        else:
          tracker = temp
      return true
    else: # tracker.value.isRunable
      tracker = tracker.next
      if tracker == start:
        return false
  return false      

proc wakeUp(tasks: TaskList) =
  tasks.candiLock.acquire()
  if tasks.sendCandidate.len > 0:
    for scMsg in tasks.sendCandidate:
      if tasks.sendWaiter.hasKey(scMsg):
        for t in tasks.sendWaiter.mget(scMsg):
          t.isRunable = true
        tasks.sendWaiter[scMsg] = newSeq[ptr Task]()
    tasks.sendCandidate = newSeq[pointer]()

  if tasks.recvCandidate.len > 0:
    for rcMsg in tasks.recvCandidate:
      if tasks.recvWaiter.hasKey(rcMsg):
        for t in tasks.recvWaiter.mget(rcMsg):
          t.isRunable = true
        tasks.recvWaiter[rcMsg] = newSeq[ptr Task]()
    tasks.recvCandidate = newSeq[pointer]()
  tasks.candiLock.release()

proc slave(tasks: TaskList) {.thread, gcsafe.} =
  var tracker:DoublyLinkedNode[Task] = nil
  tasks.lock.acquire()
  while true:
    if not runTask(tasks, tracker):
      tasks.lock.release()
      #print("task list is empty:" & $(tasks.isEmpty))
      sleep(10)
      tasks.lock.acquire()
    wakeUp(tasks)

proc chooseTaskList: int =
  var minSize =  taskListPool[0].size
  var minIndex = 0
  for i, tl in taskListPool:
    if tl.size < minSize:
      minSize = tl.size
      minIndex = i
  return minIndex

proc pRun[T](iter: TaskBody, arg: T) =
  let index = chooseTaskList()
  taskListPool[index].lock.acquire()
  var p = cast[ptr T](allocShared0(sizeof(T)))
  p[] = arg 
  taskListPool[index].list.append(Task(isRunable:true, task:iter, arg: cast[pointer](p)))
  taskListPool[index].size += 1
  taskListPool[index].lock.release()

proc initThread(index: int) =
  taskListPool[index].list = initDoublyLinkedRing[Task]()
  taskListPool[index].lock.initLock()    
  taskListPool[index].candiLock.initLock()    
  taskListPool[index].sendWaiter = initTable[pointer, seq[ptr Task]]()
  taskListPool[index].recvWaiter = initTable[pointer, seq[ptr Task]]()
  taskListPool[index].sendCandidate = newSeq[pointer]()
  taskListPool[index].recvCandidate = newSeq[pointer]()
  createThread(threadPool[index], slave, taskListPool[index].addr)

proc setup =
  for i in 0..<threadPoolSize:
    initThread(i)

setup() 

# MsgBox
type
  MsgBox[T] = ptr MsgBoxObject[T]
  MsgBoxObject[T] = object
    cap: int  # capability of this MsgBox, if < 0, unlimited
    size: int # real size of this MsgBox
    lock: Lock  # MsgBox protection lock
    data: DoublyLinkedList[T]  # data holder
    recvWaiter: seq[TaskList]  # recv waiter's TaskList
    sendWaiter: seq[TaskList]  # send waiter's TaskList

proc createMsgBox[T](cap:int = -1): MsgBox[T] =
  result = cast[MsgBox[T]](allocShared0(sizeof(MsgBoxObject[T])))
  result.cap = cap 
  result.size = 0
  result.lock.initLock()
  result.data = initDoublyLinkedList[T]()
  result.recvWaiter = newSeq[TaskList]()
  result.sendWaiter = newSeq[TaskList]()

proc deleteMsgBox[T](msgBox: MsgBox[T]) =
  msgBox.lock.deinitLock()
  msgBox.deallocShared()    

proc registerSend[T](tl: TaskList, msgBox: MsgBox[T], t: ptr Task) =   
  msgBox.sendWaiter.add(tl)
  let msgBoxPtr = cast[pointer](msgBox)
  if not tl.sendWaiter.hasKey(msgBoxPtr):
    tl.sendWaiter[msgBoxPtr] = newSeq[ptr Task]()
  tl.sendWaiter.mget(msgBoxPtr).add(t)

proc registerRecv[T](tl: TaskList, msgBox: MsgBox[T], t: ptr Task) =   
  msgBox.recvWaiter.add(tl)
  let msgBoxPtr = cast[pointer](msgBox)
  if not tl.recvWaiter.hasKey(msgBoxPtr):
    tl.recvWaiter[msgBoxPtr] = newSeq[ptr Task]()
  tl.recvWaiter.mget(msgBoxPtr).add(t)

proc notifySend[T](msgBox: MsgBox[T]) =
  for tl in msgBox.sendWaiter:
    tl.candiLock.acquire()
    tl.sendCandidate.add(cast[pointer](msgBox))
    tl.candiLock.release()
  msgBox.sendWaiter = newSeq[TaskList]()

proc notifyRecv[T](msgBox: MsgBox[T]) =
  for tl in msgBox.recvWaiter:
    tl.candiLock.acquire()
    tl.recvCandidate.add(cast[pointer](msgBox))
    tl.candiLock.release()
  msgBox.recvWaiter = newSeq[TaskList]()

template send(msgBox, msg: expr):stmt {.immediate.}=
  msgBox.lock.acquire()
  while true:
    if msgBox.cap < 0 or msgBox.size < msgBox.cap:
      msgBox.data.append(msg)
      msgBox.size += 1
      notifyRecv(msgBox)
      break
    else:  
      registerSend(tl, msgBox, t)
      t.isRunable = false
      msgBox.lock.release()
      yield BreakState(isContinue: true, isSend: true, msgBoxPtr: cast[pointer](msgBox))
      msgBox.lock.acquire()
  msgBox.lock.release()

template recv(msgBox, msg: expr): stmt {.immediate.} =
  msgBox.lock.acquire()
  while true:
    if msgBox.size > 0:
      msg = msgBox.data.head.value
      msgBox.data.remove(msgBox.data.head)  # O(1)
      msgBox.size -= 1
      notifySend(msgBox)
      break
    else:  
      #print("recv wait")
      registerRecv(tl, msgBox, t)
      t.isRunable = false
      msgBox.lock.release()
      yield BreakState(isContinue: true, isSend: false, msgBoxPtr: cast[pointer](msgBox))
      msgBox.lock.acquire()
  msgBox.lock.release()

## Macro
proc getName(node: NimNode): string {.compileTime.} =
  case node.kind
  of nnkPostfix:
    return $node[1].ident
  of nnkIdent:
    return $node.ident
  of nnkEmpty:
    return "anonymous"
  else:
    error("Unknown name.")

proc routineSingleProc(prc: NimNode): NimNode {.compileTime.} =
  if prc.kind notin {nnkProcDef, nnkLambda}:
    error("Cannot transform this node kind into an nim routine." &
          " Proc definition or lambda node expected.")

  hint("Processing " & prc[0].getName & " as an nim routine")

  let returnType = prc[3][0]

  # Verify that the return type is a void or Empty
  if returnType.kind != nnkEmpty and not (returnType.kind == nnkIdent and returnType[0].ident == !"void"):
    error("Expected return type of void got '" & $returnType & "'")
  else:
    hint("return type is void or empty")

  var procBody = prc[6]

  # -> var rArg = (cast[ptr tuple[arg1: T1, arg2: T2, ...]](arg))[]
  var rArgAssignment = newNimNode(nnkVarSection)
  var tupleList = newNimNode(nnkTupleTy)
  for i in 1 ..< prc[3].len:
    let param = prc[3][i]
    assert(param.kind == nnkIdentDefs)
    tupleList.add(param)
  rArgAssignment.add(
    newIdentDefs(
      ident("rArg"), 
      newEmptyNode(),
      newNimNode(nnkBracketExpr).add(
        newNimNode(nnkPar).add(
          newNimNode(nnkCast).add(
            newNimNode(nnkPtrTy).add(tupleList), 
            newIdentNode("arg"))))))

  # -> var arg1 = rArg.arg1
  # -> var arg2 = rArg.arg2
  # -> ...
  for i in 1 ..< prc[3].len:
    let param = prc[3][i]
    assert(param.kind == nnkIdentDefs)
    for j in 0 .. param.len - 3:
      rArgAssignment.add(
        newIdentDefs(
          param[j],
          newEmptyNode(),
          newNimNode(nnkDotExpr).add(
            ident("rArg"),
            param[j])))

  procBody.insert(0, rArgAssignment)

  var closureIterator = newProc(
    newIdentNode($prc[0].getName), 
    [
      newIdentNode("BreakState"), 
      newIdentDefs(ident("tl"), ident("TaskList")),
      newIdentDefs(ident("t"), newNimNode(nnkPtrTy).add(newIdentNode("Task"))),
      newIdentDefs(ident("arg"), ident("pointer"))
    ],
    procBody,
    nnkIteratorDef)

  closureIterator[4] = newNimNode(nnkPragma).add(newIdentNode("closure"))
  result = closureIterator 

macro routine*(prc: stmt): stmt {.immediate.} =
  ## Macro which processes async procedures into the appropriate
  ## iterators and yield statements.
  if prc.kind == nnkStmtList:
    result = newStmtList()
    for oneProc in prc:
      result.add routineSingleProc(oneProc)
  else:
    result = routineSingleProc(prc)

if isMainModule:
  var msgBox1 = createMsgBox[int]()
  var msgBox2 = createMsgBox[int]()
  defer: msgBox1.deleteMsgBox()
  defer: msgBox2.deleteMsgBox()

  proc cnt1(a, b: MsgBox[int]) {.routine.} =
    var value: int
    for i in 1 .. 5:
      print("cnt1 send: " & $i)
      send(a, i)
      recv(b, value)
      print("cnt1 recv: " & $value)
      assert(value == i)
    echo "cnt1 done"
    yield BreakState(isContinue: false, isSend: false, msgBoxPtr: nil)  

  proc cnt2(a, b: MsgBox[int]) {.routine.} =
    var value: int
    for i in 1 .. 5:
      recv(a, value)
      print("cnt2 recv: " & $value)
      assert(value == i)
      print("cnt2 send: " & $i)
      send(b, i)
    echo "cnt2 done"
    yield BreakState(isContinue: false, isSend: false, msgBoxPtr: nil)  

  pRun cnt1, (a: msgBox1, b: msgBox2)
  pRun cnt2, (a: msgBox1, b: msgBox2)
  joinThreads(threadPool)
