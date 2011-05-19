> {-# LANGUAGE GeneralizedNewtypeDeriving #-}
>

This module exports a simple, elegant implementation of the Actor Model.

> module Control.Concurrent.Actors
>     where
>
> import Control.Monad.Trans.Maybe
> import Control.Monad
> import Control.Monad.IO.Class
> import Control.Concurrent


Here we define the Actor environment, similar to IO, in which we can launch new
Actors and send messages to Actors in scope. The implementation is hidden from
the user to enforce these restrictions.

> newtype ActorM a = ActorM (MaybeT IO a) 
>                  deriving (Monad, MonadPlus)

First we define an Actor: a function that takes an input, maybe returning a new
actor:

> type Actor i = i -> ActorM (NextActor i)
> newtype NextActor i = NextActor { nextActor :: Actor i } 

Now some functions for building Actor computations:

> -- | Continue with a new Actor computation step
> continue :: Actor i -> ActorM (NextActor i)
> continue = return . NextActor

    IMPLEMENTATION NOTE: 
         when an actor terminates, its mailbox persists and we                        
         currently provide no functions to query an actor's status.                    
         Signaling an actor's termination should be done with                          
         message passing.

> -- | Actor terminating:
> done :: ActorM (NextActor i)
> done = mzero

-------------------------------------------------------------------------------

Here we define the "mailbox" that an Actor collects messages from, and other
actors send messages to. It is simply a Chan with hidden implementation.

    IMPLEMENTATION NOTE: 
         we make no attempt to ensure that only one actor is reading                    
         from a given Chan. This means two Actors can share the work                    
         reading from the same mailbox.
     
> newtype Mailbox i = Mailbox { mailbox :: Chan i }

> -- | Send a message to an Actor. Actors can only be passed messages from other
> -- actors.
> send :: (Action m)=> a -> Mailbox a -> m ()
> send a = liftIOtoA . flip writeChan a . mailbox

> -- | Read a message from a mailbox in the IO monad. This can be used as the
> -- mechanism for output from an Actor system. Blocks if the actor is empty
> receive :: Mailbox o -> IO o
> receive = readChan . mailbox

> -- | create a new mailbox that Actors can be launched to read from, or Actors
> -- can send messages to in order to communicate with other actors
> newMailbox :: (Action m)=> m (Mailbox a)
> newMailbox = liftIOtoA newChan >>= return . Mailbox

The Action class represents environments in which we can operate on actors. That
is we would like to be able to send a message in IO

> class Monad m => Action m where
>     liftIOtoA :: IO a -> m a
>
> instance Action IO where
>     liftIOtoA = id
>
> instance Action ActorM where
>     liftIOtoA = ActorM . liftIO

-------------------------------------------------------------------------------

> -- | fork an actor that reads its inputs from the supplied list. This returns
> -- after the entire input list has been processed
> runActorOn :: Actor i -> [i] -> IO ()
> runActorOn = undefined

> -- | fork an actor, returning its mailbox
> forkActor :: (Action m)=> Actor i -> m (Mailbox i)
> forkActor = undefined

> -- | fork an actor that reads from the supplied Mailbox
> forkActorUsing :: (Action m)=> Actor i -> Mailbox i -> m ()
> forkActorUsing = undefined

> --TODO: add a function that forks an actor with an iteratee and returns the
> -- resulting do

TODO
    - functions for running As and Cs, sending messages
    - classes to support running above in IO or A/CM
    - test effect of using `yield` after each actor computation
    - a seperate module implementing other abstractions using these primitives
      (see notes)

