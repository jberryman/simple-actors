This module exports some simple primitives for creating concurrent programs
using message passing. Inspired by the Actor model and notions of types of
concurrency, data, codata, etc.

> module ActorsCollectors
>     where

We'll flesh these out later:
--- IMPLEMENTATION: Should these in fact be newtypes called Actor and Collector,
--- encapsulating Maybe AND IO ??

> type AIO a = IO a
> type CIO a = IO a

First we define an Actor: a function that takes an input, maybe returning a new
actor:

--- IMPLEMENTATION: can an actor itself be Null, Or simply possibly not return 
--- a new actor? This detail should inform our implementation below:
--- SOLUTION: No, what we call an Actor is an automaton that takes an input,
--- doing something, possibly returning a new actor.
--- So: Null constructor should NOT be part of the Actor type

> type Actor i = i -> AIO (NextActor i)
> data NextActor i = NextActor { nextActor :: Actor i } 
>                  | Done

Now some functions for building Actor computations:

> -- | Continue with a new Actor computation step
> continue :: Actor i -> AIO (NextActor i)
> continue = return . NextActor

> -- | Actor terminating:
> done :: AIO (NextActor i)
> done = return Done
