> {-# LANGUAGE CPP, GeneralizedNewtypeDeriving #-}

This module exports a simple, idiomatic implementation of the Actor Model.

> module Control.Concurrent.Actors (
>
>
>     -- * Actor Behaviors
>       Behavior(..)
>     , Action()
>
>     -- ** building @Behaviors@
>     , halt
>     , receive
>
>     -- * Available actions
>     -- ** Message passing
>     , Mailbox
>     , send
>
>     -- ** Actor creation and Behavior initialization
>     {- | 
>     The spawning of a new concurrent 'Actor' can be done separately from the
>     initialization of the Actor\'s 'Behavior'. Otherwise defining
>     mutually-communicating actors would not be possible. To spawn an actor and
>     initialize its @Behavior@ in one go, you can use 'forkActorDoing'.
>     -}
>     , Actor
>     , forkActor
>     , doing
>
>     -- *** Utility functions
>     , forkActorDoing
>     , forkActorDoing_
>     , runBehavior_
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
>
> -- internal:
> import Control.Concurrent.Actors.Behavior
> import Control.Concurrent.Actors.Chans



------

These macros are only provided by cabal unfortunately.... makes it difficult to
work with GHCi:

#if !MIN_VERSION_base(4,3,0)
> void :: (Monad m)=> m a -> m ()
> void = (>> return ())
#endif

------



TODO
-----
    - do name changes for forkActorDoing, etc. (see notes)
        - forkActor -> spawnIdle
        - forkActorDoing -> spawn
        - doing / halt -> starting / stop
    - fix code for new version of Action
    x consider a possible monoid instance for Behavior
        (We can add it later if we decide it is a true monoid, but not so
        useful)
        (some actor model implementations keep a message in the mailbox
         (whatever that means) when it falls through all case statements. this is
         kind of like the situation of a do pattern-match failure, thus a monoid
         that resumes on that input makes sense)
    x don't create Behavior_ synonym, encourage polymorphic Behaviors
    - better documentation:
        - reorder export list
        - examples
        - don't make explanations of blocking behavior so prominent.
    - test if we can recover from deadlocked actor using 'doing' queuing
      behavior
    - some more involved / realistic tests
        - binary tree
        - test above on code without sender locking
    - get complete code coverage into simple test module
    - consider removing 'loggingException's, replace with 'error' call when 
       programmer error is encountered.
    - release 0.2.0 !

    - structured declarative and unit tests
    - Performance testing:
        - test performance vs. straight Chans, etc.
        - test out overhead of our various locks, especially difference if we
          scrap the snederLockMutex
    - some sort of exception handling technique via Actors
        (look at enumerator package)
    - investigate ways of positively influencing thread scheduling based on
       actor work agenda 
    -other ideas
        -strict send' function
        -IO behvior runner on a list for debugging 
        - looping based on predicate (can we get this from our instances?)
        -Behavior -> enumeratee package translator (and vice versa)
    - export some useful Actors:
        - 'loop' which keeps consuming
        - function returning an actor to "load balance" inputs over multiple
          actors
        - an actor that sends a random stream?


ACTORS AND THE ACTOR ENVIRONMENT
================================


Here we define the Actor environment, similar to IO, in which we can launch new
Actors and send messages to Actors in scope. The implementation is hidden from
the user to enforce these restrictions.
> {-
> -- | The Action environment in which 'Actors' can be spawned and sent messages.
> -- .
> -- /N.B./ The ability to use 'liftIO' here is an abstraction leak, but is convenient
> -- e.g. to allow Actors to make use of a RNG or for library designers, etc.
> newtype Action a = Action { action :: IO a }
>                  deriving (Monad, Functor, Applicative, MonadIO)
> -}


> {-
> -- | An actor works by:
> --
> --     1. receiving an input message
> --
> --     2. performing some 'Action's such as sending messages or spawning other
> --         'Actors'
> --
> --     3. returning the Behavior to be used for the next input
> -- 
> -- In our implementation a @Behavior@ is either null or is
> -- a function that takes an input, performs some 'Action's, and
> -- returns the next @Behavior@.
> --
> -- 
> data Behavior i = Recv (BehaviorStep i)
>                 | Idle
>
> type BehaviorStep i = i -> Action (Behavior i)
>


Useful instances:

> -- | 'mempty' is the null 'Behavior' and 'mappend' provides a way of sequencing
> -- behaviors; the second takes over when the first finishes.
> instance Monoid (Behavior i) where
>     mempty = Idle
>     mappend (Recv c) a2 = Recv $ (fmap (`mappend` a2)) <$> c
>     mappend _        a2 = a2
> 
> instance Cofunctor Behavior where
>     cofmap f (Recv c) = Recv $ fmap (cofmap f) . c . f
>     cofmap _ _        = Idle
> -}


CONSTRUCTING BEHAVIORS
----------------------

Functionality is based on our underlying type classes, but users shouldn't need
to import a bunch of libraries to get basic Behavior building functionality:

> -- | Aborts an Actor computation:
> -- 
> -- > halt = mzero
> halt :: Action i a
> halt = mzero


> -- | Read the current message to be processed. /N.B/ the value returned here
> -- does not change between calls in the same 'Action'.
> --
> -- > receive = ask -- ...ask and ye shall receive
> receive :: Action i i
> receive = ask


> {-
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

> -- | A @Mailbox@ allows messages to be passed asynchronously to the
> -- corresponding 'Actor' where they can be processed by a 'Behavior'. 
>
> -- A Mailbox is locked unless the corresponding Actor has an active Behavior.
> -- This means for instance that a 'send' to a Mailbox of an uninitialized
> -- Actor will block, possibly indefinitely (in which case the 'send'ing actor
> -- will be quietly garbage collected).
> data Mailbox i = Mailbox { inChan :: InChan i                  
>                          , senderLockMutex :: SenderLockMutex 
>                          }
>                    
>
> -- | A token representing a forked concurrent actor, which might be idle or
> -- running a 'Behavior' that is processing inputs sent to its 'Mailbox'
> --
> -- /IYI:/ The only thing we are allowed to do to an @Actor@ directly is to enqueue
> -- 'Behaviors' (see 'doing'). This separation of actor initialization and
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


These classes are from the split-chan package:

> instance WritableChan Mailbox where
>     writeChan b m = loggingException "writeChan Mailbox: " $
>     -- BlockedIndefinitelyOnMVar will be raised in waitSenderLock if this chan is
>     -- dead because no actors will ever work on it. The exception re-raised
>     -- here will be caught in an automatic handler installed by forkIO or will
>     -- surface in IO, depending on usage above:
>          bracket                           
>            (takeSenderLock b)            
>            (putSenderLock b)             
>            (\sl-> waitSenderLock sl >> writeChan (inChan b) m) 
>
> instance ReadableChan Actor where
>     readChan = readChan . outChan 




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
> closeStream :: Actor o -> IO ()
> closeStream str = blockSenders str >> giveUpStream str
> --openStream str = acquireStream str >> unblockSenders str 






CREATING CHANS / SENDING MESSAGES
==================================

Note, after much thought I've decided the abstraction that is the module
interface should differ from the implementation for conceptual simplicity.

So what we call Actor is actual a set of Chans and locks, but we treat it like a
token corresponding to an actor running or idling in the ether. Furthermore,
this doesn't actual do a forkIO, which we treat as an unimportant implementation
detail.

> -- | Create a new concurrent 'Actor', returning its 'Mailbox'. Using 'doing' to
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

> -}

> {-

SEND FUNCTIONS
---------------

> -- | Send a message asynchronously. This can be used to send messages to other
> -- Actors via a 'Mailbox', or used as a means of output from the Actor system
> -- to IO.
> -- .
> -- /Sends to a Mailbox/:
> -- This does not wait for the Actor to receive the message before returning, 
> -- but will block while no Behavior is active in the corresponding Actor. The
> -- runtime will notice deadlocks and quietly garbage collect senders to a dead
> -- actor.
> -- . 
> -- > send b = liftIO . writeChan b
> send :: (MonadIO m, WritableChan c)=> c a -> a -> m ()
> send b = liftIO . writeChan b
>

> -}


RUNNING AND FORKING ACTORS
===========================

> maybeDo :: (BehaviorStep i -> IO ()) -> Behavior i -> IO ()
> maybeDo f (Recv c) = f c
> maybeDo _ _        = return ()


Internal function that feeds the actor computation its values:

> -- N.B.: Be careful not to throw away any input here when we hit the null
> -- behavior:
> actorRunner :: Actor i -> Behavior i -> IO ()
> actorRunner str = maybeDo step
>     where step b = readChan str >>= action . b >>= actorRunner str



RUNNING
--------

These work in IO and returning () when the actor finishes with done/mzero:

> -- | run a Behavior_ in the main thread, returning when the computation exits
> runBehavior_ :: Behavior () -> IO ()
> runBehavior_ = maybeDo step 
>     where step b = action (b ()) >>= runBehavior_


FORKING
--------

> -- | Fork an actor 'doing' a 'Behavior' directly, returning its input 'Mailbox'
> forkActorDoing :: (MonadIO m)=> Behavior i -> m (Mailbox i)
> forkActorDoing a = do
>     (b,str) <- forkActor
>     doing str a
>     return b
>
> -- | fork a looping computation which starts immediately. Equivalent to
> -- launching a @Behavior ()@ and another 'Behavior' that sends an infinite stream of
> -- ()s to the former.
> forkActorDoing_ :: (MonadIO m)=> Behavior () -> m ()
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


