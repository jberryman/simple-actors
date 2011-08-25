> {-# LANGUAGE CPP, GeneralizedNewtypeDeriving #-}

This module exports a simple, idiomatic implementation of the Actor Model.

> module Control.Concurrent.Actors (
>
>     -- * Actor computations
>       Behavior(..)
>     , Action()
>     -- ** Type and Function synonyms for building @Behaviors@
>     , Behavior_
>     , continue_
>     , continue
>     , done
>
>     -- * Message passing and IO
>     , send
>     -- ** Mailbox / Actor pair
>     , forkActor
>     , Mailbox
>     , Actor
>
>     -- * Running Actors
>     , forkActorDoing
>     , doing
>     , forkActorDoing_
>     -- ** Running Actor computations in current IO thread
>     , runBehaviorUsing
>     , runBehavior_
>
>     -- * Supporting classes
>     , module Data.Cofunctor 
>
>     ) where
>
> import Data.Monoid
> import Control.Monad
> import Control.Monad.IO.Class
> import Control.Concurrent.MVar
> import Control.Concurrent(forkIO)
> import Control.Applicative
> import Control.Exception
>
> -- from the chan-split package
> import Control.Concurrent.Chan.Split
> import Control.Concurrent.Chan.Class
> import Data.Cofunctor




------

These macros are only provided by cabal unfortunately.... makes it difficult to
work with GHCi:

#if !MIN_VERSION_base(4,3,0)
> void :: (Monad m)=> m a -> m ()
> void = (>> return ())
#endif

------

It would be nice to put this in a CPP conditional block. Does cabal define a CPP
variable when tests are run?

> dEBUGGING :: Bool
> dEBUGGING = True



TODO
-----
    - branch and
        - make name changes
        - fix module organization and documentation
        - remove trivial functions
        - merge 
    - merge, fix names in test modules
    - check out what will happen with MVar in mutex in Mailbox
    - testing

    - better documentation:
        - examples

    - test performance
    - export some useful Actors:
        - 'loop' which keeps consuming
        - function returning an actor to "load balance" inputs over multiple
          actors


ACTORS AND THE ACTOR ENVIRONMENT
================================


Here we define the Actor environment, similar to IO, in which we can launch new
Actors and send messages to Actors in scope. The implementation is hidden from
the user to enforce these restrictions.

> -- | The Action environment in which Actors can be spawned and sent messages.
> -- .
> -- /N.B./ The ability to use 'liftIO' here is an abstraction leak, but is convenient
> -- e.g. to allow Actors to make use of a RNG or for library designers.
> newtype Action a = Action { action :: IO a }
>                  deriving (Monad, Functor, Applicative, MonadIO)


First we define a Behavior: either the null behavior, or a function that takes 
an input, performs some Actions and returns the next Behavior:

> newtype Behavior i = Behavior { stepBehavior :: Maybe (BehaviorStep i) }
>                 --deriving (Applicative,Alternative)
>
> type BehaviorStep i = i -> Action (Behavior i)
>
> -- behavior fmap for cleaning up definitions below:
> bfmap :: (BehaviorStep i -> BehaviorStep i') -> Behavior i -> Behavior i'
> bfmap f = Behavior . fmap f . stepBehavior
>
> -- | 'mempty' is the null 'Behavior' and 'mappend' provides a way of sequencing
> -- behaviors; the second takes over when the first finishes.
> instance Monoid (Behavior i) where
>     mempty = Behavior Nothing
>     mappend (Behavior Nothing) a2 = a2
>     mappend a1 a2 = bfmap mappendChild a1
>         where mappendChild = fmap $ fmap (`mappend` a2)
> 
> instance Cofunctor Behavior where
>     cofmap f = bfmap (\s-> (cofmap f <$>) . s . f)


TRIVIAL HELPERS
----------------

These might make building actor computations more readable:

> -- | Continue with a new Actor computation step
> -- 
> -- > continue = return
> continue :: Behavior i -> Action (Behavior i)
> continue = return
>
> -- | Actor terminating:
> --
> -- > done = return mempty
> done :: Action (Behavior i)
> done = return mempty


A Behavior is just an Behavior that ignores its input. We provide some useful
functions for building and running such computations:

> -- | A 'Behavior' that discards its input
> type Behavior_ = Behavior ()
>
> -- | Continue with a 'Behavior_' computation, lifting it into the current
> -- 'Behavior' input type
> --
> -- > continue_ = continue . cofmap (const ())
> continue_ :: Behavior_ -> Action (Behavior i) 
> continue_ = return . cofmap (const ())



MESSAGE CHANNELS
================

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
> -- 'Actor'
> data Mailbox i = Mailbox { 
>                      inChan :: InChan i
>                    , senderLockMutex :: SenderLockMutex 
>                    }
>
> -- | A token representing a forked concurrent actor, which might be idle or
> -- running a 'Behavior' that is processing inputs sent to its 'Mailbox'
> --
> -- /IYI:/ The only thing we are allowed to do to an @Actor@ directly is to enqueue
> -- 'Behaviors' (see 'foo'). This separation of actor initialization and
> -- behavior enqueueing is necessary to allow e.g. two actors access each to
> -- the other\'s Mailbox
> data Actor o = Actor { outChan :: OutChan o
>                      , senderLock :: SenderLock 
>                      , forkLock :: ForkLock     
>                      }                          
>                         
>
> instance Cofunctor Mailbox where
>     cofmap f (Mailbox c l) = Mailbox (cofmap f c) l
> 
> instance Functor Actor where
>     fmap f (Actor c sl fl) = Actor (fmap f c) sl fl



LOCKING MECHANISMS
==================

We use a system of locks to enforce these properties of the environment:

    1) Sends will block until there is an Actor processing the stream

    2) Attempting to fork on an Actor will block until no other Actor
        is processing the stream


SEND LOCKS
-----------

All the senders who want to send block on this mutex:

> newtype SenderLockMutex = SLM { getMutex :: MVar SenderLock }
>
> takeSenderLock :: Mailbox i -> IO SenderLock
>  -- TODO: BlockedIndefinitelyOnMVar HERE MEANS: the SenderLock was never
>  -- returned and we lost the game. Re-raise a more meaningful exception
> takeSenderLock = loggingException "BUG: takeSenderLock" . 
>                   takeMVar . getMutex . senderLockMutex
>
> putSenderLock :: Mailbox i -> SenderLock -> IO ()
>  -- TODO: BlockedIndefinitelyOnMVar HERE MEANS: the (some?) SenderLock was
>  -- 'put' or never taken or aliens. We lost the game and should re-raise a
>  -- humbling appology
> putSenderLock m = loggingException "BUG: putSenderLock" . 
>                    putMVar (getMutex $ senderLockMutex m)


They then must readMVar here before writing to the Chan. This inner MVar is
copied in the corresponding Actor:

> newtype SenderLock = SL { getSLock :: MVar () }
>
> waitSenderLock :: SenderLock -> IO ()
>  -- TODO: BlockedIndefinitelyOnMVar HERE MEANS: (assuming we didn't do
>  -- something stupid like use any other function to get or put this MVar) that no
>  -- Actor will ever be working on the corresponding stream we're dealing with.
> waitSenderLock = loggingException "waitSenderLock" . 
>                   readMVar . getSLock  -- take + put

We must use this double-lock to ensure that we can block senders without waiting
in line behind all the senders currently in the queue to do a 'take' on the
MVar.


FORK LOCKS
-----------

While an actor is reading from a stream it takes the () and when it finishes (or
dies with an exception) it returns it. Thus forks should block and queue fairly
on this:

> newtype ForkLock = FL { getFLock :: MVar () }


Here are some helpers for dealing with lock types:

> unblockSenders, blockSenders, acquireStream, giveUpStream :: Actor o -> IO ()
> -- Exceptions raised here mean our lock implementation is buggy:
> acquireStream = loggingException "BUG: acquireStream" . 
>                  takeMVar . getFLock . forkLock
> giveUpStream = loggingException "BUG: giveUpStream" . 
>                  flip putMVar () . getFLock . forkLock
> unblockSenders = loggingException "BUG: unblockSenders" .
>                  flip putMVar () . getSLock . senderLock
> blockSenders = loggingException "BUG: blockSenders" .
>                  takeMVar . getSLock . senderLock 
>
> closeStream, openStream :: Actor o -> IO ()
> closeStream str = blockSenders str >> giveUpStream str
> openStream str = acquireStream str >> unblockSenders str 


HOW WE USE THE LOCKS
--------------------

    forkActor (Actor):
        ...
    forkActorOn:
        ...
    send:
        ...
    done (or exception handled):
        ...



CREATING CHANS / SENDING MESSAGES
==================================

Note, after much thought I've decided the abstraction that is the module
interface should differ from the implementation for conceptual simplicity.

So what we call Actor is actual a set of Chans and locks, but we treat it like a
token corresponding to an actor running or idling in the ether. Furthermore,
this doesn't actual do a forkIO, which we treat as an unimportant implementation
detail.

> -- | Create a new concurrent 'Actor', returning its 'Mailbox'. Using 'foo' to
> -- initialize a 'Behavior' for the @Actor@ will cause it to unlock its
> -- 'Mailbox' and begin accepting and processing inputs.
> forkActor :: (MonadIO m)=> m (Mailbox a, Actor a)
> forkActor = liftIO $ do
>     (inC,outC) <- newSplitChan
>      -- fork Lock starts initially full:
>     fLock <- FL <$> newMVar ()
>      -- sender lock starts initially empty (forker fills):
>     sLock <- SL <$> newEmptyMVar
>     sMutex <- SLM <$> newMVar sLock
>     return (Mailbox inC sMutex, Actor outC sLock fLock)


A channel of communication should never have senders without a receiver. To
enforce this idea, we make 'send' operations block until an Actor is consuming
the corresponding stream. When the runtime determines that a sender will be
blocked indefinitely, an exception will be raised (BlockedIndefinitelyOnMVar)
something that would not happen with plain Chans. 

This doesn't guarantee that all messages in the Chan will be processed or that a
chan won't fill faster than its messages are consumed; it simply aids garbage
collection and keeps things a little more controlled.



SEND FUNCTIONS
---------------

> -- | Send a message asynchronously. This can be used to send messages to other
> -- Actors via a 'Mailbox', or used as a means of output from the Actor system.
> -- .
> -- /Sends to a Mailbox/:
> -- This does not wait for the Actor to receive the message before returning, 
> -- but will block while no Actor is processing the corresponding Actor;
> -- If the runtime determines that a new Actor will never take over, an
> -- exception will be raised.
> -- . 
> -- > send b = liftIO . writeChan b
> send :: (MonadIO m, WritableChan c)=> c a -> a -> m ()
> send b = liftIO . writeChan b
>

These classes are from the split-chan package:

> instance WritableChan Mailbox where
>     writeChan = putMessage
>
> instance ReadableChan Actor where
>     readChan = readChan . outChan 


Internal function:

> putMessage :: Mailbox a -> a -> IO ()
> putMessage b m = loggingException "putMessage" $
>     -- BlockedIndefinitelyOnMVar will be raised in waitSenderLock if this chan is
>     -- dead because no actors will ever work on it. The exception re-raised
>     -- here will be caught in an automatic handler installed by forkIO or will
>     -- surface in IO, depending on usage above:
>          bracket                           
>            (takeSenderLock b)            
>            (putSenderLock b)             
>            (\sl-> waitSenderLock sl >> writeChan (inChan b) m) 




RUNNING AND FORKING ACTORS
===========================

Internal function that feeds the actor computation its values:

> -- N.B.: Be careful not to throw away any input here when we hit the null
> -- behavior:
> actorRunner :: Actor i -> Behavior i -> IO ()
> actorRunner str = maybeDo step . stepBehavior 
>     where step beh = readChan str >>= action . beh >>= actorRunner str



RUNNING
--------

These work in IO and returning () when the actor finishes with done/mzero:

> -- | run a 'Behavior' in the main thread, returning when it completes. 
> -- Exceptions are not caught:
> runBehaviorUsing :: Actor i -> Behavior i -> IO ()
> runBehaviorUsing str a =  
>       bracket_
>         (openStream str)
>         (closeStream str)
>         (actorRunner str a)


...and a variation where no Chan is involved:

> -- | run a Behavior_ actor in the main thread, returning when the computation exits
> runBehavior_ :: Behavior_ -> IO ()
> runBehavior_ = maybeDo step . stepBehavior
>     where step beh = action (beh ()) >>= runBehavior_


FORKING
--------

> -- | fork an actor, returning its input 'Mailbox'
> forkActorDoing :: (MonadIO m)=> Behavior i -> m (Mailbox i)
> forkActorDoing a = do
>     (b,str) <- forkActor
>     doing str a
>     return b
>
> -- | fork a looping computation which starts immediately. Equivalent to
> -- launching an 'Behavior_' and another 'Behavior' that sends an infinite stream of
> -- ()s
> forkActorDoing_ :: (MonadIO m)=> Behavior_ -> m ()
> forkActorDoing_ = liftIO . void . forkIO . runBehavior_  



This is how the internal forking procedure below works, w.r.t locks, etc:

    block waiting to take forkLock
    forkIO:                       
        unblock senders
        run computation
        on exit: 
            block senders
            giveUpStream to other forkers


> -- | Enqueue a 'Behavior' for an 'Actor' to perform. This will block while the
> -- @Actor@ is already 'doing' a @Behavior@, returning when the @Actor@ begins
> -- the passed @Behavior@.
> doing :: (MonadIO m)=> Actor i -> Behavior i -> m ()
> doing str ac = liftIO $ void $ do
>     -- blocks, waiting for other actors to give up control:
>     acquireStream str
>     -- Fork actor computation, waiting for first input.
>     forkIO $ bracket_ 
>                  (unblockSenders str) 
>                  (closeStream str)
>                  (actorRunner str ac)




TESTING AND HELPERS:
=====================


> maybeDo :: (Monad m) => (a -> m ()) -> Maybe a -> m ()
> maybeDo = maybe (return ())



Occurences of these should turn into "return ()" when the CPP sets 
    dEBUGGING = False

> {-
> -- When dEBUGGING is False at compile time and optimizations are turned on, 
> -- this should completely disappear
> assertIO :: (MonadIO m)=> m Bool -> m ()
> assertIO a = when dEBUGGING $ 
>     a >>= liftIO . flip assert (return ())
> -}
>
> -- rethrow exceptions, logging to stdout if dEBUGGING
> loggingException :: String -> IO a -> IO a
> loggingException s io 
>     | dEBUGGING = Control.Exception.catch io handler
>     | otherwise = io
>             where handler :: SomeException -> IO a
>                   handler e = do when dEBUGGING $ putStrLn $ ((s++": ")++) $ show e
>                                  throwIO e
