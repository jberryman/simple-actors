> {-# LANGUAGE CPP, GeneralizedNewtypeDeriving #-}

This module exports a simple, idiomatic implementation of the Actor Model.

> module Control.Concurrent.Actors (
>
>
>     -- * Actor Behaviors
>       Behavior(..)
>     , Action()
>
>     -- * Available actions
>     -- ** Message passing
>     , Mailbox
>     , send
>     , receive
>
>     -- ** Creating Actors and starting Behaviors
>     {- | 
>     The spawning of a new concurrent 'Actor' can be done separately from the
>     initialization of the Actor\'s 'Behavior'. Otherwise defining
>     mutually-communicating actors would not be possible. To spawn an actor and
>     initialize its @Behavior@ in one go, you can use 'spawn'.
>     -}
>     , Actor
>     , spawnIdle
>     , starting
>     , spawn
>     -- ** Exiting an actor computation
>     , stop
>
>     -- * Utility functions
>     , spawn_
>     , runBehavior_
>     , runBehavior 
>
>     ) where
>
> import Control.Monad
> import Control.Monad.Reader(ask)
> import qualified Data.Foldable as F
> import Control.Monad.IO.Class
> import Control.Concurrent(forkIO)
> import Control.Exception
>
> -- from the chan-split package
> import Control.Concurrent.Chan.Split
>
> -- internal:
> import Control.Concurrent.Actors.Behavior
> import Control.Concurrent.Actors.Chans



------ CPP MACROS ------

These macros are only provided by cabal unfortunately.... makes it difficult to
work with GHCi:

#if !MIN_VERSION_base(4,3,0)
> void :: (Monad m)=> m a -> m ()
> void = (>> return ())
#endif

------------------------



TODO
-----
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
    - test if we can recover from deadlocked actor using 'starting' queuing
      behavior
    - some more involved / realistic tests
        - binary tree
        - initial benchmarking:
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
    - export some useful Actors and global thingies
        - 'loop' which keeps consuming (is this provided by a class?)
        - function returning an actor to "load balance" inputs over multiple
          actors
        - an actor that sends a random stream?
        - a pre-declared Mailbox for IO?



ACTIONS
-------

Functionality is based on our underlying type classes, but users shouldn't need
to import a bunch of libraries to get basic Behavior building functionality:

> -- | Aborts an Actor computation:
> -- 
> -- > stop = mzero
> stop :: Action i a
> stop = mzero


> -- | Read the current message to be processed. /N.B/ the value returned here
> -- does not change between calls in the same 'Action'.
> --
> -- > receive = ask  -- ...and ye shall receive
> receive :: Action i i
> receive = ask


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



FORKING AND RUNNING ACTORS:
===========================


See Control.Concurrent.Actors.Chans for implementation of locks used here:

> -- | Enqueue a 'Behavior' for an 'Actor' to perform. This will block while the
> -- @Actor@ has already started a @Behavior@, returning when the @Actor@ begins
> -- the passed @Behavior@.
> starting :: (MonadIO m)=> Actor i -> Behavior i -> m ()
> starting str ac = liftIO $ void $ do
>     -- blocks, waiting for other actors to give up control:
>     acquireStream str
>     -- Fork actor computation, waiting for first input.
>     forkIO $ bracket_ 
>                  (unblockSenders str) 
>                  (closeStream str)
>                  (actorRunner str ac)



RUNNING ACTORS
--------------

Internal:

> actorRunner :: Actor i -> Behavior i -> IO ()
> actorRunner str b =
>     readChan str >>= runBehaviorStep b >>= F.mapM_ (actorRunner str)

These work in IO, returning () when the actor finishes with done/mzero:

> -- | run a @Behavior ()@ in the main thread, returning when the computation exits
> runBehavior_ :: Behavior () -> IO ()
> runBehavior_ b = runBehavior b [(),()..]
>
> -- | run a 'Behavior' in the IO monad, taking its "messages" from the list.
> -- Useful for debugging.
> runBehavior :: Behavior a -> [a] -> IO ()
> runBehavior b (a:as) = runBehaviorStep b a >>= F.mapM_ (`runBehavior` as)
> runBehavior _ _      = return ()



FORKING ACTORS
--------------

> -- | Fork an actor 'starting' a 'Behavior' directly, returning its input 'Mailbox'
> spawn :: (MonadIO m)=> Behavior i -> m (Mailbox i)
> spawn b = do
>     (m,a) <- spawnIdle
>     a `starting` b
>     return m
>
> -- | fork a looping computation which starts immediately. Equivalent to
> -- launching a @Behavior ()@ and another 'Behavior' that sends an infinite stream of
> -- ()s to the former.
> spawn_ :: (MonadIO m)=> Behavior () -> m ()
> spawn_ = liftIO . void . forkIO . runBehavior_  
