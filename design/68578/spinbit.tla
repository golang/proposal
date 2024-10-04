------------------------------ MODULE spinbit ------------------------------
EXTENDS TLC, Integers, Sequences, FiniteSets

CONSTANT NumThreads
CONSTANT NumAcquires
CONSTANT NumSpins \* performance tunable "spin"
CONSTANT WakeAny \* reduce state space: wake any of the sleepers
CONSTANT NULL \* [ model value ]

ASSUME NumThreads >= 1
ASSUME NumAcquires >= 0
ASSUME NumSpins >= 0
ASSUME WakeAny \in BOOLEAN

Threads == 1..NumThreads

(* --algorithm spinbit

variables

    \* logical owner
    owner = NULL;

    \* lock state, stored in l.key word
    l_key_locked = FALSE; \* bit 0
    l_key_sleeping = FALSE; \* bit 1
    l_key_spinning = FALSE; \* bit 63

    \* local variables
    v_locked = [t \in Threads |-> FALSE];
    v_sleeping = [t \in Threads |-> FALSE];
    v_spinning = [t \in Threads |-> FALSE];
    v8_locked = [t \in Threads |-> FALSE];
    v8_sleeping = [t \in Threads |-> FALSE];
    weSpin = [t \in Threads |-> FALSE];
    i = [t \in Threads |-> 0];

    \* OS state
    sleepers = {};

    \*
    acquisitions = 0;

    \* performance tunables
    spin = NumSpins;

define

    TypeInvariant ==
        /\ owner \in Threads \union {NULL}
        /\ l_key_locked \in BOOLEAN
        /\ l_key_sleeping \in BOOLEAN
        /\ l_key_spinning \in BOOLEAN
        /\ \A t \in Threads: v_locked[t] \in BOOLEAN
        /\ \A t \in Threads: v_sleeping[t] \in BOOLEAN
        /\ \A t \in Threads: v_spinning[t] \in BOOLEAN
        /\ \A t \in Threads: v8_locked[t] \in BOOLEAN
        /\ \A t \in Threads: v8_sleeping[t] \in BOOLEAN
        /\ \A t \in Threads: weSpin[t] \in BOOLEAN
        /\ \A t \in Threads: i[t] \in Nat
        /\ sleepers \subseteq Threads
        /\ acquisitions \in Nat

    NoLostWakeups ==
        (Cardinality(sleepers) > 0) ~> (Cardinality(sleepers) = 0)

    HaveAcquisitions ==
        <>[](acquisitions >= NumAcquires)

end define;

\* This is a lock, so if a process dies while holding it the rest of the simulation
\* won't be able to make progress. We need "fair process" so the threads don't die.
fair process thread \in Threads
begin
    NonCriticalSection:
        if acquisitions >= NumAcquires then
            goto Done;
        end if;

    SpeculativeGrab:
        \* v8 = atomic.Xchg8(k8, mutexLocked)
        v8_locked[self] := l_key_locked;
        v8_sleeping[self] := l_key_sleeping;
        l_key_locked := TRUE;
        l_key_sleeping := FALSE;
    SpeculativeGrabCheck:
        if v8_locked[self] = FALSE then
            if v8_sleeping[self] = TRUE then
                \* atomic.Or8(k8, mutexSleeping)
                l_key_sleeping := TRUE;
            end if;
            goto Locked;
        else
            \* var v uintptr = mutexLocked
            v_locked[self] := TRUE;
            v_sleeping[self] := FALSE;
            v_spinning[self] := FALSE;
            weSpin[self] := FALSE;
        end if;

    EnterSlowPath:
        i[self] := 0;

    TryAcquire:
        if v_locked[self] = TRUE then
            goto SetSleepBit
        else
            if weSpin[self] then
                \* next := (v &^ mutexSpinning) | mutexLocked | mutexSleeping
                \* if atomic.Casuintptr(&l.key, v, next) {
                if v_locked[self] = l_key_locked
                    /\ v_sleeping[self] = l_key_sleeping
                    /\ v_spinning[self] = l_key_spinning then
                    l_key_locked := TRUE;
                    l_key_sleeping := TRUE;
                    l_key_spinning := FALSE;
                    goto Locked;
                end if;
            else
                \* prev8 := atomic.Xchg8(k8, mutexLocked|mutexSleeping)
                \* if prev8&mutexLocked == 0 {
                if l_key_locked = FALSE then
                    l_key_locked := TRUE;
                    l_key_sleeping := TRUE;
                    goto Locked;
                else
                    l_key_locked := TRUE;
                    l_key_sleeping := TRUE;
                end if;
            end if;
        end if;
    TryAcquireLoop:
        \* v = atomic.Loaduintptr(&l.key)
        v_locked[self] := l_key_locked;
        v_sleeping[self] := l_key_sleeping;
        v_spinning[self] := l_key_spinning;
        goto TryAcquire;

    SetSleepBit:
        \* atomic.Or8(k8, mutexSleeping)
        if v_sleeping[self] = FALSE then
            l_key_sleeping := TRUE;
            v_sleeping[self] := TRUE;
        end if;

    SetSpinBit:
        \* if !weSpin && atomic.Xchg8(key8Upper(&l.key), mutexSpinning>>((goarch.PtrSize-1)*8)) == 0 {
        if weSpin[self] = FALSE then
            weSpin[self] := (l_key_spinning = FALSE);
            l_key_spinning := TRUE;
        end if;

    DoSpin:
        if weSpin[self] = TRUE then
            if i[self] < spin then
                \* procyield(active_spin_cnt)
                \* v = atomic.Loaduintptr(&l.key)
                v_locked[self] := l_key_locked;
                v_sleeping[self] := l_key_sleeping;
                v_spinning[self] := l_key_spinning;
                goto TryAcquire;
            else
                weSpin[self] := FALSE;
                \* atomic.Xchg8(key8Upper(&l.key), 0)
                l_key_spinning := FALSE;
            end if;
        end if;

    Sleep:
        \* v = atomic.Loaduintptr(&l.key)
        v_locked[self] := l_key_locked;
        v_sleeping[self] := l_key_sleeping;
        v_spinning[self] := l_key_spinning;
    Futex:
        if v_locked[self] = FALSE then
            goto TryAcquire;
        else
            \* futexsleep(k32, uint32(v|mutexSleeping), -1)
            if l_key_locked = v_locked[self]
                /\ l_key_sleeping = TRUE then
                sleepers := sleepers \union {self};
            end if;
        end if;

    Sleeping:
        await self \notin sleepers;
        i[self] := 0;
        \* v = atomic.Loaduintptr(&l.key)
        v_locked[self] := l_key_locked;
        v_sleeping[self] := l_key_sleeping;
        v_spinning[self] := l_key_spinning;
        goto TryAcquire;

    Locked:
        owner := self;
    CriticalSection:
        acquisitions := acquisitions + 1;
    Unlock:
        owner := NULL;
        \* prev8 := atomic.Xchg8(key8(&l.key), 0)
        v8_locked[self] := l_key_locked;
        v8_sleeping[self] := l_key_sleeping;
        l_key_locked := FALSE;
        l_key_sleeping := FALSE;
        if v8_sleeping[self] = TRUE then
            goto Wakeup;
        else
            goto NonCriticalSection;
        end if;

    Wakeup:
        \* v := atomic.Loaduintptr(&l.key)
        v_locked[self] := l_key_locked;
        v_sleeping[self] := l_key_sleeping;
        v_spinning[self] := l_key_spinning;
    Wake2:
        if v_spinning[self] = FALSE then
            if Cardinality(sleepers) > 0 then
                if WakeAny then
                    with other = CHOOSE other \in sleepers: TRUE do
                        sleepers := sleepers \ {other};
                    end with;
                else
                    with other \in sleepers do
                        sleepers := sleepers \ {other};
                    end with;
                end if;
            end if;
        end if;
        goto NonCriticalSection;

end process;

end algorithm; *)
\* BEGIN TRANSLATION (chksum(pcal) = "a993096" /\ chksum(tla) = "41bbe278")
VARIABLES owner, l_key_locked, l_key_sleeping, l_key_spinning, v_locked, 
          v_sleeping, v_spinning, v8_locked, v8_sleeping, weSpin, i, sleepers, 
          acquisitions, spin, pc

(* define statement *)
TypeInvariant ==
    /\ owner \in Threads \union {NULL}
    /\ l_key_locked \in BOOLEAN
    /\ l_key_sleeping \in BOOLEAN
    /\ l_key_spinning \in BOOLEAN
    /\ \A t \in Threads: v_locked[t] \in BOOLEAN
    /\ \A t \in Threads: v_sleeping[t] \in BOOLEAN
    /\ \A t \in Threads: v_spinning[t] \in BOOLEAN
    /\ \A t \in Threads: v8_locked[t] \in BOOLEAN
    /\ \A t \in Threads: v8_sleeping[t] \in BOOLEAN
    /\ \A t \in Threads: weSpin[t] \in BOOLEAN
    /\ \A t \in Threads: i[t] \in Nat
    /\ sleepers \subseteq Threads
    /\ acquisitions \in Nat

NoLostWakeups ==
    (Cardinality(sleepers) > 0) ~> (Cardinality(sleepers) = 0)

HaveAcquisitions ==
    <>[](acquisitions >= NumAcquires)


vars == << owner, l_key_locked, l_key_sleeping, l_key_spinning, v_locked, 
           v_sleeping, v_spinning, v8_locked, v8_sleeping, weSpin, i, 
           sleepers, acquisitions, spin, pc >>

ProcSet == (Threads)

Init == (* Global variables *)
        /\ owner = NULL
        /\ l_key_locked = FALSE
        /\ l_key_sleeping = FALSE
        /\ l_key_spinning = FALSE
        /\ v_locked = [t \in Threads |-> FALSE]
        /\ v_sleeping = [t \in Threads |-> FALSE]
        /\ v_spinning = [t \in Threads |-> FALSE]
        /\ v8_locked = [t \in Threads |-> FALSE]
        /\ v8_sleeping = [t \in Threads |-> FALSE]
        /\ weSpin = [t \in Threads |-> FALSE]
        /\ i = [t \in Threads |-> 0]
        /\ sleepers = {}
        /\ acquisitions = 0
        /\ spin = NumSpins
        /\ pc = [self \in ProcSet |-> "NonCriticalSection"]

NonCriticalSection(self) == /\ pc[self] = "NonCriticalSection"
                            /\ IF acquisitions >= NumAcquires
                                  THEN /\ pc' = [pc EXCEPT ![self] = "Done"]
                                  ELSE /\ pc' = [pc EXCEPT ![self] = "SpeculativeGrab"]
                            /\ UNCHANGED << owner, l_key_locked, 
                                            l_key_sleeping, l_key_spinning, 
                                            v_locked, v_sleeping, v_spinning, 
                                            v8_locked, v8_sleeping, weSpin, i, 
                                            sleepers, acquisitions, spin >>

SpeculativeGrab(self) == /\ pc[self] = "SpeculativeGrab"
                         /\ v8_locked' = [v8_locked EXCEPT ![self] = l_key_locked]
                         /\ v8_sleeping' = [v8_sleeping EXCEPT ![self] = l_key_sleeping]
                         /\ l_key_locked' = TRUE
                         /\ l_key_sleeping' = FALSE
                         /\ pc' = [pc EXCEPT ![self] = "SpeculativeGrabCheck"]
                         /\ UNCHANGED << owner, l_key_spinning, v_locked, 
                                         v_sleeping, v_spinning, weSpin, i, 
                                         sleepers, acquisitions, spin >>

SpeculativeGrabCheck(self) == /\ pc[self] = "SpeculativeGrabCheck"
                              /\ IF v8_locked[self] = FALSE
                                    THEN /\ IF v8_sleeping[self] = TRUE
                                               THEN /\ l_key_sleeping' = TRUE
                                               ELSE /\ TRUE
                                                    /\ UNCHANGED l_key_sleeping
                                         /\ pc' = [pc EXCEPT ![self] = "Locked"]
                                         /\ UNCHANGED << v_locked, v_sleeping, 
                                                         v_spinning, weSpin >>
                                    ELSE /\ v_locked' = [v_locked EXCEPT ![self] = TRUE]
                                         /\ v_sleeping' = [v_sleeping EXCEPT ![self] = FALSE]
                                         /\ v_spinning' = [v_spinning EXCEPT ![self] = FALSE]
                                         /\ weSpin' = [weSpin EXCEPT ![self] = FALSE]
                                         /\ pc' = [pc EXCEPT ![self] = "EnterSlowPath"]
                                         /\ UNCHANGED l_key_sleeping
                              /\ UNCHANGED << owner, l_key_locked, 
                                              l_key_spinning, v8_locked, 
                                              v8_sleeping, i, sleepers, 
                                              acquisitions, spin >>

EnterSlowPath(self) == /\ pc[self] = "EnterSlowPath"
                       /\ i' = [i EXCEPT ![self] = 0]
                       /\ pc' = [pc EXCEPT ![self] = "TryAcquire"]
                       /\ UNCHANGED << owner, l_key_locked, l_key_sleeping, 
                                       l_key_spinning, v_locked, v_sleeping, 
                                       v_spinning, v8_locked, v8_sleeping, 
                                       weSpin, sleepers, acquisitions, spin >>

TryAcquire(self) == /\ pc[self] = "TryAcquire"
                    /\ IF v_locked[self] = TRUE
                          THEN /\ pc' = [pc EXCEPT ![self] = "SetSleepBit"]
                               /\ UNCHANGED << l_key_locked, l_key_sleeping, 
                                               l_key_spinning >>
                          ELSE /\ IF weSpin[self]
                                     THEN /\ IF v_locked[self] = l_key_locked
                                                 /\ v_sleeping[self] = l_key_sleeping
                                                 /\ v_spinning[self] = l_key_spinning
                                                THEN /\ l_key_locked' = TRUE
                                                     /\ l_key_sleeping' = TRUE
                                                     /\ l_key_spinning' = FALSE
                                                     /\ pc' = [pc EXCEPT ![self] = "Locked"]
                                                ELSE /\ pc' = [pc EXCEPT ![self] = "TryAcquireLoop"]
                                                     /\ UNCHANGED << l_key_locked, 
                                                                     l_key_sleeping, 
                                                                     l_key_spinning >>
                                     ELSE /\ IF l_key_locked = FALSE
                                                THEN /\ l_key_locked' = TRUE
                                                     /\ l_key_sleeping' = TRUE
                                                     /\ pc' = [pc EXCEPT ![self] = "Locked"]
                                                ELSE /\ l_key_locked' = TRUE
                                                     /\ l_key_sleeping' = TRUE
                                                     /\ pc' = [pc EXCEPT ![self] = "TryAcquireLoop"]
                                          /\ UNCHANGED l_key_spinning
                    /\ UNCHANGED << owner, v_locked, v_sleeping, v_spinning, 
                                    v8_locked, v8_sleeping, weSpin, i, 
                                    sleepers, acquisitions, spin >>

TryAcquireLoop(self) == /\ pc[self] = "TryAcquireLoop"
                        /\ v_locked' = [v_locked EXCEPT ![self] = l_key_locked]
                        /\ v_sleeping' = [v_sleeping EXCEPT ![self] = l_key_sleeping]
                        /\ v_spinning' = [v_spinning EXCEPT ![self] = l_key_spinning]
                        /\ pc' = [pc EXCEPT ![self] = "TryAcquire"]
                        /\ UNCHANGED << owner, l_key_locked, l_key_sleeping, 
                                        l_key_spinning, v8_locked, v8_sleeping, 
                                        weSpin, i, sleepers, acquisitions, 
                                        spin >>

SetSleepBit(self) == /\ pc[self] = "SetSleepBit"
                     /\ IF v_sleeping[self] = FALSE
                           THEN /\ l_key_sleeping' = TRUE
                                /\ v_sleeping' = [v_sleeping EXCEPT ![self] = TRUE]
                           ELSE /\ TRUE
                                /\ UNCHANGED << l_key_sleeping, v_sleeping >>
                     /\ pc' = [pc EXCEPT ![self] = "SetSpinBit"]
                     /\ UNCHANGED << owner, l_key_locked, l_key_spinning, 
                                     v_locked, v_spinning, v8_locked, 
                                     v8_sleeping, weSpin, i, sleepers, 
                                     acquisitions, spin >>

SetSpinBit(self) == /\ pc[self] = "SetSpinBit"
                    /\ IF weSpin[self] = FALSE
                          THEN /\ weSpin' = [weSpin EXCEPT ![self] = (l_key_spinning = FALSE)]
                               /\ l_key_spinning' = TRUE
                          ELSE /\ TRUE
                               /\ UNCHANGED << l_key_spinning, weSpin >>
                    /\ pc' = [pc EXCEPT ![self] = "DoSpin"]
                    /\ UNCHANGED << owner, l_key_locked, l_key_sleeping, 
                                    v_locked, v_sleeping, v_spinning, 
                                    v8_locked, v8_sleeping, i, sleepers, 
                                    acquisitions, spin >>

DoSpin(self) == /\ pc[self] = "DoSpin"
                /\ IF weSpin[self] = TRUE
                      THEN /\ IF i[self] < spin
                                 THEN /\ v_locked' = [v_locked EXCEPT ![self] = l_key_locked]
                                      /\ v_sleeping' = [v_sleeping EXCEPT ![self] = l_key_sleeping]
                                      /\ v_spinning' = [v_spinning EXCEPT ![self] = l_key_spinning]
                                      /\ pc' = [pc EXCEPT ![self] = "TryAcquire"]
                                      /\ UNCHANGED << l_key_spinning, weSpin >>
                                 ELSE /\ weSpin' = [weSpin EXCEPT ![self] = FALSE]
                                      /\ l_key_spinning' = FALSE
                                      /\ pc' = [pc EXCEPT ![self] = "Sleep"]
                                      /\ UNCHANGED << v_locked, v_sleeping, 
                                                      v_spinning >>
                      ELSE /\ pc' = [pc EXCEPT ![self] = "Sleep"]
                           /\ UNCHANGED << l_key_spinning, v_locked, 
                                           v_sleeping, v_spinning, weSpin >>
                /\ UNCHANGED << owner, l_key_locked, l_key_sleeping, v8_locked, 
                                v8_sleeping, i, sleepers, acquisitions, spin >>

Sleep(self) == /\ pc[self] = "Sleep"
               /\ v_locked' = [v_locked EXCEPT ![self] = l_key_locked]
               /\ v_sleeping' = [v_sleeping EXCEPT ![self] = l_key_sleeping]
               /\ v_spinning' = [v_spinning EXCEPT ![self] = l_key_spinning]
               /\ pc' = [pc EXCEPT ![self] = "Futex"]
               /\ UNCHANGED << owner, l_key_locked, l_key_sleeping, 
                               l_key_spinning, v8_locked, v8_sleeping, weSpin, 
                               i, sleepers, acquisitions, spin >>

Futex(self) == /\ pc[self] = "Futex"
               /\ IF v_locked[self] = FALSE
                     THEN /\ pc' = [pc EXCEPT ![self] = "TryAcquire"]
                          /\ UNCHANGED sleepers
                     ELSE /\ IF l_key_locked = v_locked[self]
                                 /\ l_key_sleeping = TRUE
                                THEN /\ sleepers' = (sleepers \union {self})
                                ELSE /\ TRUE
                                     /\ UNCHANGED sleepers
                          /\ pc' = [pc EXCEPT ![self] = "Sleeping"]
               /\ UNCHANGED << owner, l_key_locked, l_key_sleeping, 
                               l_key_spinning, v_locked, v_sleeping, 
                               v_spinning, v8_locked, v8_sleeping, weSpin, i, 
                               acquisitions, spin >>

Sleeping(self) == /\ pc[self] = "Sleeping"
                  /\ self \notin sleepers
                  /\ i' = [i EXCEPT ![self] = 0]
                  /\ v_locked' = [v_locked EXCEPT ![self] = l_key_locked]
                  /\ v_sleeping' = [v_sleeping EXCEPT ![self] = l_key_sleeping]
                  /\ v_spinning' = [v_spinning EXCEPT ![self] = l_key_spinning]
                  /\ pc' = [pc EXCEPT ![self] = "TryAcquire"]
                  /\ UNCHANGED << owner, l_key_locked, l_key_sleeping, 
                                  l_key_spinning, v8_locked, v8_sleeping, 
                                  weSpin, sleepers, acquisitions, spin >>

Locked(self) == /\ pc[self] = "Locked"
                /\ owner' = self
                /\ pc' = [pc EXCEPT ![self] = "CriticalSection"]
                /\ UNCHANGED << l_key_locked, l_key_sleeping, l_key_spinning, 
                                v_locked, v_sleeping, v_spinning, v8_locked, 
                                v8_sleeping, weSpin, i, sleepers, acquisitions, 
                                spin >>

CriticalSection(self) == /\ pc[self] = "CriticalSection"
                         /\ acquisitions' = acquisitions + 1
                         /\ pc' = [pc EXCEPT ![self] = "Unlock"]
                         /\ UNCHANGED << owner, l_key_locked, l_key_sleeping, 
                                         l_key_spinning, v_locked, v_sleeping, 
                                         v_spinning, v8_locked, v8_sleeping, 
                                         weSpin, i, sleepers, spin >>

Unlock(self) == /\ pc[self] = "Unlock"
                /\ owner' = NULL
                /\ v8_locked' = [v8_locked EXCEPT ![self] = l_key_locked]
                /\ v8_sleeping' = [v8_sleeping EXCEPT ![self] = l_key_sleeping]
                /\ l_key_locked' = FALSE
                /\ l_key_sleeping' = FALSE
                /\ IF v8_sleeping'[self] = TRUE
                      THEN /\ pc' = [pc EXCEPT ![self] = "Wakeup"]
                      ELSE /\ pc' = [pc EXCEPT ![self] = "NonCriticalSection"]
                /\ UNCHANGED << l_key_spinning, v_locked, v_sleeping, 
                                v_spinning, weSpin, i, sleepers, acquisitions, 
                                spin >>

Wakeup(self) == /\ pc[self] = "Wakeup"
                /\ v_locked' = [v_locked EXCEPT ![self] = l_key_locked]
                /\ v_sleeping' = [v_sleeping EXCEPT ![self] = l_key_sleeping]
                /\ v_spinning' = [v_spinning EXCEPT ![self] = l_key_spinning]
                /\ pc' = [pc EXCEPT ![self] = "Wake2"]
                /\ UNCHANGED << owner, l_key_locked, l_key_sleeping, 
                                l_key_spinning, v8_locked, v8_sleeping, weSpin, 
                                i, sleepers, acquisitions, spin >>

Wake2(self) == /\ pc[self] = "Wake2"
               /\ IF v_spinning[self] = FALSE
                     THEN /\ IF Cardinality(sleepers) > 0
                                THEN /\ IF WakeAny
                                           THEN /\ LET other == CHOOSE other \in sleepers: TRUE IN
                                                     sleepers' = sleepers \ {other}
                                           ELSE /\ \E other \in sleepers:
                                                     sleepers' = sleepers \ {other}
                                ELSE /\ TRUE
                                     /\ UNCHANGED sleepers
                     ELSE /\ TRUE
                          /\ UNCHANGED sleepers
               /\ pc' = [pc EXCEPT ![self] = "NonCriticalSection"]
               /\ UNCHANGED << owner, l_key_locked, l_key_sleeping, 
                               l_key_spinning, v_locked, v_sleeping, 
                               v_spinning, v8_locked, v8_sleeping, weSpin, i, 
                               acquisitions, spin >>

thread(self) == NonCriticalSection(self) \/ SpeculativeGrab(self)
                   \/ SpeculativeGrabCheck(self) \/ EnterSlowPath(self)
                   \/ TryAcquire(self) \/ TryAcquireLoop(self)
                   \/ SetSleepBit(self) \/ SetSpinBit(self) \/ DoSpin(self)
                   \/ Sleep(self) \/ Futex(self) \/ Sleeping(self)
                   \/ Locked(self) \/ CriticalSection(self) \/ Unlock(self)
                   \/ Wakeup(self) \/ Wake2(self)

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == (\E self \in Threads: thread(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Threads : WF_vars(thread(self))

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* END TRANSLATION 

=============================================================================
\* Modification History
\* Last modified Tue Oct 01 13:18:42 PDT 2024 by rhysh
\* Created Tue Sep 17 12:10:43 PDT 2024 by rhysh
