> {-# LANGUAGE GeneralizedNewtypeDeriving #-}
>

This module exports some simple primitives for creating concurrent programs
using message passing. Inspired by the Actor model and notions of types of
concurrency, data, codata, etc.

> module ActorsCollectors
>     where
>
> import Control.Monad.Trans.Maybe
> import Control.Monad


Here we define the Actor environment, similar to IO, in which we can launch new
Actors and send messages to actors in scope:

--- IMPLEMENTATION: Consider calling this ActorO for Output, like the IO monad but
--- no input is possible (i.e. only messages are sent). Or perhaps MO and MI for
--- Actor and Collector monads respectively.

> newtype ActorM a = AM (MaybeT IO a) deriving (Monad, MonadPlus)

First we define an Actor: a function that takes an input, maybe returning a new
actor:

> type Actor i = i -> ActorM (NextActor i)
> newtype NextActor i = NextActor { nextActor :: Actor i } 

Now some functions for building Actor computations:

> -- | Continue with a new Actor computation step
> continue :: Actor i -> ActorM (NextActor i)
> continue = return . NextActor

> -- | Actor terminating:
> done :: ActorM (NextActor i)
> done = mzero
