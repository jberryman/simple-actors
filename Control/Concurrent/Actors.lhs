> {-# LANGUAGE GeneralizedNewtypeDeriving #-}

This module exports a simple, idiomatic implementation of the Actor Model.

> module Control.Concurrent.Actors (
>     -- * Actor computations
>       Actor
>     , NextActor(..)
>     , ActorM()
>     -- ** Building Actors
>     , continue
>     , done
>     , aseq
>     -- * Message passing and IO
>     , send
>     -- ** Actor system output:
>     , receive
>     , receiveList
>     -- ** Mailbox
>     , Mailbox()
>     , newMailbox
>     -- * Running Actors
>     , Action()
>     , forkActor
>     , forkActorUsing
>     , runActorOn
>     ) where
>
> import Control.Monad
> import Control.Monad.IO.Class
> import Control.Monad.Trans.Maybe
> import Control.Concurrent
> import Control.Applicative


Here we define the Actor environment, similar to IO, in which we can launch new
Actors and send messages to Actors in scope. The implementation is hidden from
the user to enforce these restrictions.

> -- | The Actor encironment in which Actors can be spawned and sent messages
> newtype ActorM a = ActorM { actorM :: MaybeT IO a }
>                  deriving (Monad, Functor, Applicative, Alternative, MonadPlus, MonadIO)
>
> runActorM = runMaybeT . actorM

First we define an Actor: a function that takes an input, maybe returning a new
actor:

    TODO: Consider making Actor the newtype and eliminating NextActor
      newtype Actor i = Actor { actor :: i -> ActorM (Actor i) }
      continue :: (i -> ActorM (Actor i)) -> ActorM (Actor i)


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

    IMPLEMENTATION NOTE: 
        We might find that we can use the monoid abstraction, or 
        that we should make Actor a newtype for other reasons. For
        now we have this for composing

> -- | compose two actors. The second will take over when the first exits
> aseq :: Actor i -> Actor i -> Actor i
> aseq f g i = NextActor <$> (nextf <|> return g)
>     where nextf = (`aseq` g) . nextActor <$> f i


-------------------------------------------------------------------------------


Here we define the "mailbox" that an Actor collects messages from, and other
actors send messages to. It is simply a Chan with hidden implementation.

    IMPLEMENTATION NOTE: 
         we make no attempt to ensure that only one actor is reading                    
         from a given Chan. This means two Actors can share the work                    
         reading from the same mailbox.
         
         If we want to change this in the future, Mailbox will contain
         a type :: TVar ThreadID

         To implement synchronous chans (or singly-buffered chans), 
         we can use a SyncMailbox type containing an MVar and
         possibly another Var for ensuring syncronicity. An MVar
         writer will never block indefinitely. Use a class for writing
         and reading these mailbox types.

     
> -- | the buffered message passing medium used between actors
> newtype Mailbox i = Mailbox { mailbox :: Chan i }
>
> -- | Send a message to an Actor. Actors can only be passed messages from other
> -- actors.
> send :: (Action m)=> a -> Mailbox a -> m ()
> send a = liftIOtoA . flip writeChan a . mailbox

> -- | Read a message from a mailbox in the IO monad. This can be used as the
> -- mechanism for output from an Actor system. Blocks if the actor is empty
> receive :: Mailbox o -> IO o
> receive = readChan . mailbox

> -- | Return a lazy list of mailbox contents
> receiveList :: Mailbox o -> IO [o]
> receiveList = getChanContents . mailbox

> -- | create a new mailbox that Actors can be launched to read from, or Actors
> -- can send messages to in order to communicate with other actors
> newMailbox :: (Action m)=> m (Mailbox a)
> newMailbox = liftIOtoA newChan >>= return . Mailbox


The Action class represents environments in which we can operate on actors. That
is we would like to be able to send a message in IO

> -- | monads in the Action class can participate in message passing and other
> -- Actor operations
> class Monad m => Action m where
>     liftIOtoA :: IO a -> m a
>
> instance Action IO where
>     liftIOtoA = id
>
> instance Action ActorM where
>     liftIOtoA = ActorM . liftIO


-------------------------------------------------------------------------------


> -- | fork an actor, returning its mailbox
> forkActor :: (Action m)=> Actor i -> m (Mailbox i)
> forkActor a = do
>     b <- newMailbox
>     forkActorUsing a b
>     return b
>     
> -- | fork an actor that reads from the supplied Mailbox
> forkActorUsing :: (Action m)=> Actor i -> Mailbox i -> m ()
> forkActorUsing a b = do
>     liftIOtoA $ forkIO $ actorHandler (mailbox b) a
>     return ()
>     --void $ liftIOtoA $ forkIO $ actorHandler (mailbox b) a 
>


This function may be useful in the main thread as a way of "pushing" data into
the actor system from some coordinating actor. I'm not sure yet.

> -- | fork an actor that reads its inputs from the supplied list. This returns
> -- after the entire input list has been processed by the actor or the actor
> -- terminates
> runActorOn :: Actor i -> [i] -> IO ()
> runActorOn a l = do
>     b <- newMailbox
>     forkIO $ writeList2Chan (mailbox b) l
>     actorHandler (mailbox b) a


Internal function that feeds the actor computation its values. This may be
extended to support additional functionality in the future.

> actorHandler :: Chan i -> Actor i -> IO ()
> actorHandler c = loop
>     where loop a = readChan c >>= 
>                     runActorM . a >>= 
>                      -- is a `yield` useful here?
>                      maybe (return ()) (loop . nextActor)

