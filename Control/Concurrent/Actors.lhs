> {-# LANGUAGE GeneralizedNewtypeDeriving, ViewPatterns #-}

This module exports a simple, idiomatic implementation of the Actor Model.

> module Control.Concurrent.Actors (
>     -- * Actor computations
>       Actor(..)
>     , Action()
>     -- ** Type and Function synonyms for building Actors
>     , Actor_
>     , continue_
>     , continue
>     , done
>     -- * Message passing and IO
>     , send
>     , sendSync
>     -- ** Mailbox / Stream pairs
>     , Stream(newChanPair)
>     -- ** Actor system output
>     , receive
>     , receiveList
>     -- * Running Actors
>     , MonadAction()
>     , forkActor
>     , forkActorUsing
>     , forkActor_
>     -- ** Running in current IO thread
>     , runActorUsing
>     , runActor_
>     -- * Supporting classes
>     , Cofunctor(..)
>     ) where
>
> import Control.Monad
> import Control.Monad.IO.Class
> import Control.Monad.Trans.Maybe
> import Control.Concurrent
> import Control.Applicative


TODO
=====

FIRST:
-------
    x remove aseq
    x re-define Actor as a newtype
    x change ActorM to Action, Action class to MonadAction
    x new mailbox types, in pairs with MVar, class instances for both (and Cofunctor)
    x 'newChanPair' polymorphic with supporting Output class
        Fix things to work with new Actors and Chans:
        - re-define 'send' function
    - create a 'sendSync'
    - make forkActor block until exclusive access granted
    - better documentation:
        - show implementation in docs when it reveals something
        - examples
        - explanations when useful

LATER:
------
    - test performance of send blocking and not blocking
    - automated tests
    - built-in awesome exception handling, that helps the garbage collector
    - export some useful Actors:
        - 'loop' which keeps consuming
        - function returning an actor to "load balance" inputs over multiple
          actors


Here we define the Actor environment, similar to IO, in which we can launch new
Actors and send messages to Actors in scope. The implementation is hidden from
the user to enforce these restrictions.

> -- | The Actor encironment in which Actors can be spawned and sent messages
> newtype Action a = Action { action :: MaybeT IO a }
>                  deriving (Monad, Functor, Applicative, 
>                            Alternative, MonadPlus, MonadIO)
>
> runAction = runMaybeT . action

First we define an Actor: a function that takes an input, maybe returning a new
actor:

> newtype Actor i = Actor { stepActor :: i -> Action (Actor i) }

Now some functions for making building Actor computations perhaps more readable:

> -- | Continue with a new Actor computation step
> -- 
> -- > continue = return
> continue :: Actor i -> Action (Actor i)
> continue = return
>
> -- | Actor terminating:
> --
> -- > done = mzero
> done :: Action (Actor i)
> done = mzero


    > aseq :: Actor i -> Actor i -> Actor i
    > aseq f g i = NextActor <$> (nextf <|> return g)
    >     where nextf = (`aseq` g) . nextActor <$> f i


An Actor_ is just an Actor that ignores its input. We provide some useful
functions for building and running such computations:

> -- | An Actor that discards its input
> type Actor_ = Actor ()
>
> -- | Continue with an Actor_ computation, lifting it into the current Actor
> -- input type
> --
> -- > continue_ = cofmap (const ())
> continue_ :: Actor_ -> Action (Actor i)
> continue_ = return . cofmap (const ())


Here we define the Channels for sending messages to Actors and launching actors
to read from. These chans come in pairs, allowing for more fine-grained and
explicit control over the ability to pass messages to Actors, and launch
Actors on Chans.

It also lets us make the Chan types instances of different classes, e.g. the
output chan types can be a Functor.

Finally, having a seperate Chan type that can only be read in IO makes intended
functionality of the library more explicit.

> -- | The input portion of our buffered message-passing medium. Actors can 
> -- send messages to a Mailbox, where they will supply a corresponding
> -- 'ActorStream' or 'IOStream'
> newtype Mailbox i = Mailbox { mailbox :: ChanPair i }
>
> -- | A stream of messages, received via a corresponding 'Mailbox', which can
> -- /only/ act as input for an 'Actor' computation
> data ActorStream i = ActorStream { actorStream :: ChanPair i }
>

    NOTE: we don't use a locking mechanism for IOStream for now, but may 
     put some kind of signalling mechanism in later. This would probably 
     have to use STM to be useful and avoid race conditions.

> -- | A stream of messages, received via a corresponding 'Mailbox', which can
> -- be freely read from only in the IO Monad.
> data IOStream i = IOStream { ioStream :: MessageChan i }

See below for explanation of locking mechanism used here:

> data ChanPair i = ChanPair { actorStream :: MessageChan i
>                            , readLock :: ReadLock 
>                            , sendLock :: SendLock
>                            }

To enable 'send's and 'fork's to block when a Mailbox pair has no Actor
reading it, we share two MVars between the pair which act as locks:

> type ReadLock = MVar ()

    HOW WE USE ReadLock:
        initialization:
            The MVar starts empty initially
        forkActorOn:
            blocks until it can write () to MVar, at which point the Actor starts
        actor exit, or exception:
            takes value from MVar

> type SendLock = MVar ()

    HOW WE USE SendLock:
        actor start (single thread):
            actor runner that acquired ReadLock puts ()
        send (many concurrent):
            blocks on a 'readMVar'
        actor exit, or exception (single thread):
            actor runner takes (), blocking any reader threads

    PRETTY ILLUSTRATION: 

                ^ (5)             ^ (4)
      exit:     |                 |           read:
             ----------        ----------  <--------> (3b)
            | ReadLock |      | SendLock |    ---> 
             ----------        ----------    --->  (3a)
                ^^^               ^        
      fork:     |||               |
                   (1)             (2)

    LOCKING PROCEDURE: 
      fork:
        1) many threads trying to fork on chan block on `putMVar`
        2) forking thread that acquired 'ReadLock' puts to empty SendLock
            (assert empty)
      actor running, send:
        3) a. Many threads trying to `send` blocked on `readMVar`
           b. One wakes up, takes/puts, then sends a message to the Chan
      exit:
        4) actor runner thread blocks until last sender returns lock, then it
           'takes', blocking other senders
        5) actor runner thread 'takes' ReadLock, letting other runners fork it

    PROBLEMS:
        step 4) we want the runner to be able to immediately block senders, not
                get stuck in the queue
            
        

The internal message type. The addition of an MVar allows for syncronous message
passing between Actors:

> type MessageChan i = Chan (Message i)
> newtype Message i = Message (i, Maybe SyncToken)
>                   deriving Functor
> type SyncToken = MVar ()

    HOW WE USE SyncToken, PASSED WITH EACH MESSAGE:
        send:
            Pass empty MVar, don't check it
        sendSync:
            Pass empty MVar, block until we can pop ()
        actor receiver:
            before acting on message, write a () to MVar


> -- | The class of Streams for output with a corresponding 'Mailbox'
> class Stream s where
>     newChanPair :: (MonadAction m)=> m (Mailbox a, s a)
>     newChanPair = liftIOtoA $ 
>         wrapStream <$> (ChanPair <$> newChan <*> newEmptyMVar)
>
>     -- INTERNAL:
>     wrapStream :: ChanPair i -> s i
>
> instance Stream ActorStream where
>     wrapStream = ActorStream
>
> instance Stream IOStream where
>     wrapStream = IOStream . actorStream
>


    IMPLEMENTATION NOTE: 
        We allow sending of messages to Actors in IO, treating the 
        main thread as something of an Actor with the special
        privilege to read arbitrarily from an IOStream.

We are always synchronous IN THE MEDIUM and may be synchronous IN THE MESSAGE as
well by choosing the appropriate 'send' function. 

...

A channel of communication should never have senders without a receiver. To
enforce this idea, we make 'send' operations block until an Actor is consuming
the corresponding stream. When the runtime determines that a sender will be
blocked indefinitely, an exception will be raised: BlockedIndefinitelyOnMVar. 

This doesn't guarentee that all messages in the Chan will be processed, but in
such a situation, hopefully a BlockedIndefinitelyOnMVar will be raised, which we
can catch and (maybe) use to help garbage collection on the underlying Chan and
in general keep things nice.


    TODO: - change 'done' to 'giveUpControlToAnotherActor'?
          - Change 'forkActorOn' to 'queueActorOn'?

> -- | Send a message to an Actor asynchronously. However blocks if there is no
> Actor currently processing the stream.
> send :: (MonadAction m)=> Mailbox a -> a -> m ()
> send b = liftIOtoA . writeChan (mailbox b) . Message . (,Nothing)
>
> -- | Send a message to an Actor. Block until the actor accepts message. If the
> -- Actor exits, and no other actors take over, this will block forever.
> sendSync :: (MonadAction m)=> Mailbox a -> a -> m ()
> sendSync (mailbox-> b) a = do
>     -- block until this Chan has an Actor reading inputs from it:
>     -- NOTE: strictly speaking, this introduces a race condition, but for
>     --       our purposes I think this is okay.
>     readMVar $ readLock b
>     sv <- newEmptyMVar
>     writeChan
>     -- block until the actor starts processing our message
>     takeMVar sv >> return ()
>     

> -- | Read a message from a mailbox in the IO monad. This can be used as the
> -- mechanism for output from an Actor system. Blocks if the actor is empty
> receive :: Mailbox o -> IO o
> receive = readChan . mailbox

> -- | Return a lazy list of mailbox contents
> receiveList :: Mailbox o -> IO [o]
> receiveList = getChanContents . mailbox

> -- | create a new mailbox that Actors can be launched to read from or
> -- send messages to in order to communicate with other actors
> newMailbox :: (MonadAction m)=> m (Mailbox a)
> newMailbox = liftIOtoA newChan >>= return . Mailbox


The MonadAction class represents environments in which we can operate on actors. That
is we would like to be able to send a message in IO

> -- | monads in the MonadAction class can participate in message passing and other
> -- Actor operations
> class Monad m => MonadAction m where
>     liftIOtoA :: IO a -> m a
>
>     forkA :: IO () -> m ()
>     forkA io = liftIOtoA $ forkIO io >> return ()
>
> instance MonadAction IO where
>     liftIOtoA = id
>
> instance MonadAction Action where
>     liftIOtoA = Action . liftIO




> -- | fork an actor, returning its mailbox
> forkActor :: (MonadAction m)=> Actor i -> m (Mailbox i)
> forkActor a = do
>     b <- newMailbox
>     forkActorUsing b a
>     return b
>     
> -- | fork an actor that reads from the supplied Mailbox
> forkActorUsing :: (MonadAction m)=> Mailbox i -> Actor i -> m ()
> forkActorUsing b = forkA . actorHandler b
>
> -- | fork a looping computation which starts immediately
> forkActor_ :: (MonadAction m)=> Actor_ -> m ()
> forkActor_ = forkA . runActor_  
>
> -- | run an Actor_ actor in the main thread, returning when the computation exits
> runActor_ :: Actor_ -> IO ()
> runActor_ l = runAction l >>= 
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
>                     runAction . a >>= 
>                      maybe (return ()) (loop . nextActor)

This doesn't seem to be a popular class, unfortunately but it's useful for us
here: it lets us transform a Mailbox/sink/processor of one input type to another

It can be found in 

> class Cofunctor f where
>     cofmap :: (a -> b) -> (f b -> f a)
>
> instance Cofunctor Mailbox where
>     ...
> 
> instance Cofunctor Actor where
>     ...
> 

TODO: make this into cofmap instance for Actor:

    > -- | Continue with an Actor_ computation, lifting it into the current Actor
    > -- input type
    > continue_ :: Actor_ -> Action (NextActor i)
    > continue_ = fmap (NextActor . fixConst . nextActor)
    >     where fixConst c = const $ continue_ $ c ()

