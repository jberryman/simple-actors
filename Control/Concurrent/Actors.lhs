> {-# LANGUAGE GeneralizedNewtypeDeriving, ViewPatterns #-}

This module exports a simple, idiomatic implementation of the Actor Model.

> module Control.Concurrent.Actors (
>     -- * Actor computations
>       Actor
>     , Actor_
>     , NextActor(..)
>     , ActorM()
>     -- ** Building Actors
>     , continue
>     , continue_
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
>     , forkActor_
>     , runActorUsing
>     , runActor_
>     ) where
>
> import Control.Monad
> import Control.Monad.IO.Class
> import Control.Monad.Trans.Maybe
> import Control.Concurrent
> import Control.Applicative

TODO?:
    - Function for combining mailboxes (make a monoid? Only allow doing this in IO?)

    Alternately: what if we delegated a single 'mainActor' that is in IO, and which
    any Actor can send a message to? This would be an IO event loop and we would run
    this IO loop from 'main' which would block until... so tired.

    RE: Mailbox Class:
        - Having such a class is a decent idea anyway since we may want to have
          a synchronous Mailbox type, in which case we should 

Here we define the Actor environment, similar to IO, in which we can launch new
Actors and send messages to Actors in scope. The implementation is hidden from
the user to enforce these restrictions.

> -- | The Actor encironment in which Actors can be spawned and sent messages
> newtype ActorM a = ActorM { actorM :: MaybeT IO a }
>                  deriving (Monad, Functor, Applicative, 
>                            Alternative, MonadPlus, MonadIO)
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


An Actor_ is just an Actor that ignores its input. We provide some useful
functions for building and running such computations:

> -- | An Actor that discards its input
> type Actor_ = ActorM (NextActor ())
>
> -- | Continue with an Actor_ computation, lifting it into the current Actor
> -- input type
> continue_ :: Actor_ -> ActorM (NextActor i)
> continue_ = fmap (NextActor . fixConst . nextActor)
>     where fixConst c = const $ continue_ $ c ()



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

     
> -- | a buffered message passing medium. This is used to send messages to
> -- Actors and can also be used as a sink for output into IO from an Actor
> -- system.
> newtype Mailbox i = Mailbox { mailbox :: Chan i }
>

    IMPLEMENTATION NOTE: 
        We allow sending of messages to Actors in IO, treating the 
        main thread as something of an Actor with special privileges;
        It can launch actors and message them, but also read as it 
        pleases from Mailboxes


> -- | Send a message to an Actor. Actors can only be passed messages from other
> -- actors.
> send :: (Action m)=> Mailbox a -> a -> m ()
> send b = liftIOtoA . writeChan (mailbox b)

> -- | Read a message from a mailbox in the IO monad. This can be used as the
> -- mechanism for output from an Actor system. Blocks if the actor is empty
> receive :: Mailbox o -> IO o
> receive = readChan . mailbox

> -- | Return a lazy list of mailbox contents
> receiveList :: Mailbox o -> IO [o]
> receiveList = getChanContents . mailbox

> -- | create a new mailbox that Actors can be launched to read from or
> -- send messages to in order to communicate with other actors
> newMailbox :: (Action m)=> m (Mailbox a)
> newMailbox = liftIOtoA newChan >>= return . Mailbox


The Action class represents environments in which we can operate on actors. That
is we would like to be able to send a message in IO

> -- | monads in the Action class can participate in message passing and other
> -- Actor operations
> class Monad m => Action m where
>     liftIOtoA :: IO a -> m a
>
>     forkA :: IO () -> m ()
>     forkA io = liftIOtoA $ forkIO io >> return ()
>
> instance Action IO where
>     liftIOtoA = id
>
> instance Action ActorM where
>     liftIOtoA = ActorM . liftIO




> -- | fork an actor, returning its mailbox
> forkActor :: (Action m)=> Actor i -> m (Mailbox i)
> forkActor a = do
>     b <- newMailbox
>     forkActorUsing b a
>     return b
>     
> -- | fork an actor that reads from the supplied Mailbox
> forkActorUsing :: (Action m)=> Mailbox i -> Actor i -> m ()
> forkActorUsing b = forkA . actorHandler b
>
> -- | fork a looping computation which starts immediately
> forkActor_ :: (Action m)=> Actor_ -> m ()
> forkActor_ = forkA . runActor_  
>
> -- | run an Actor_ actor in the main thread, returning when the computation exits
> runActor_ :: Actor_ -> IO ()
> runActor_ l = runActorM l >>= 
>              maybe (return ()) (runActor_ . ($ ()) .  nextActor)

>
> -- | run an Actor in the main thread, returning when the Actor exits
> runActorUsing :: Mailbox i -> Actor i -> IO ()
> runActorUsing = actorHandler


Internal function that feeds the actor computation its values. This may be
extended to support additional functionality in the future.

> actorHandler :: Mailbox i -> Actor i -> IO ()
> actorHandler (mailbox->c) = loop
>     where loop a = readChan c >>= 
>                     runActorM . a >>= 
>                      maybe (return ()) (loop . nextActor)

