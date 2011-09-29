> {-# LANGUAGE CPP, GeneralizedNewtypeDeriving, MultiParamTypeClasses #-}

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
>     , Mailbox()
>     , send
>     , receive
>
>     -- ** Creating Mailboxes and spawning actors
>     {- | 
>     Message passing occurs through the medium of a 'Mailbox'/'Messages'
>     pair. A 'Behavior' can be 'spawn'ed directly, returning its @Mailbox@; or
>     a chan pair can be first instantiated with 'newMailbox' and then a
>     @Behavior@ run explicitly on a @Messages@ with 'spawnReading'.
>
>     The latter is necessary for spawning mutually-communicating actors, and
>     allows one to share a Messages between actors.
>     -}
>     , Messages()
>     , newMailbox
>     , spawnReading
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
>
> import Data.Functor.Contravariant
> -- from the chan-split package
> import Control.Concurrent.Chan.Split
>
> -- internal:
> import Control.Concurrent.Actors.Behavior



------ CPP MACROS ------

These macros are only provided by cabal unfortunately.... makes it difficult to
work with GHCi:

#if !MIN_VERSION_base(4,3,0)
> void :: (Monad m)=> m a -> m ()
> void = (>> return ())
#endif

------------------------




CHAN TYPES
==========

> -- | Instantiate a new @Mailbox@ where actors can 'send' messages, and a
> -- corresponding message stream that an actor can process. Messages are
> -- streamed in the order they are received.
> --
> -- > newMailbox = liftIO newSplitChan
> newMailbox :: (MonadIO m)=> m (Mailbox a, Messages a)
> newMailbox = liftIO newSplitChan
>
> -- | One can 'send' a messages to a @Mailbox@ where it will be processed by an
> -- actor running on the corresponding 'Messages'
> newtype Mailbox a = Mailbox { inChan :: InChan a }
>       deriving (Contravariant)
>
> -- | Messages sent to a 'Mailbox' will be streamed in FIFO order to the
> -- corresponding @Messages@. an actor can be spawned on a specific
> -- @Messages@ using 'spawnReading'. Multiple actors can process input from
> -- the same @Messages@.
> newtype Messages a = Messages { outChan :: OutChan a }
>       deriving (Functor) 
>
> -- Not sure how to derive this or if possible:
> instance SplitChan Mailbox Messages where
>     readChan = readChan . outChan
>     writeChan = writeChan . inChan
>     writeList2Chan = writeList2Chan . inChan
>
> instance NewSplitChan Mailbox Messages where
>     newSplitChan = fmap (\(i,o)-> (Mailbox i, Messages o)) newSplitChan
>
> ---- TODO: consider defining instance of NewSplitChan if we want 'spawn' to be
> ---- polymorphic over it. Inwhich case newMailbox = liftIO . newSplitChan



TODO
-----
    x get rid of all locks
    x re-name 'Actor' to InputStream 
                or... Mailbox / Messages 
              'starting' -> spawnReading
              'spawnIdle -> newMedium..
    x create simple newtype-wrapped chan pairs (above) and define contravariant
      and SplitChan, NewChan instances for them
    x do NewChanSplit class
    x redefine spawnReading to be polymorphic (also spawn? NO), as well as send
      (over chan pair)
    x consider a possible monoid instance for Behavior
        (We can add it later if we decide it is a true monoid, but not so
        useful)
        (some actor model implementations keep a message in the mailbox
         (whatever that means) when it falls through all case statements. this is
         kind of like the situation of a do pattern-match failure, thus a monoid
         that resumes on that input makes sense)
    - some more involved / realistic tests
        - binary tree
        - initial benchmarking:
            - test above on code without sender locking
    - get complete code coverage into simple test module
    - make sure we define all convenient exports and wrapper functions
    - clean up function docs (refs to locks, etc.)
    - better documentation:
        - examples
        - don't make explanations of blocking behavior so prominent.
    - release 0.1.0 !

 0.2.0:
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
        - consider adding a global output chan and actorOutput :: IO String
        - strict send' function
        - IO behvior runner on a list for debugging 
        - looping based on predicate (can we get this from our instances?)
        -Behavior -> enumeratee package translator (and vice versa)
    - export some useful Actors and global thingies
        - 'loop' which keeps consuming (is this provided by a class?)
        - function returning an actor to "load balance" inputs over multiple
          actors
        - an actor that sends a random stream?
        - a pre-declared Mailbox for IO?
    - provide an "adapter" for amazon SQS, allowing truly distributed message
      passing


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
> -- > send b = liftIO . writeChan b
> send :: (MonadIO m, SplitChan c x)=> c a -> a -> m ()
> send b = liftIO . writeChan b



FORKING AND RUNNING ACTORS:
===========================


> -- | Enqueue a 'Behavior' for an Actor to perform. This will block while the
> -- @Actor@ has already started a @Behavior@, returning when the @Actor@ begins
> -- the passed @Behavior@.
> spawnReading :: (MonadIO m, SplitChan x c)=> c i -> Behavior i -> m ()
> spawnReading str = liftIO . void . forkIO . actorRunner str


RUNNING ACTORS
--------------

Internal:

> actorRunner :: (SplitChan x c)=> c i -> Behavior i -> IO ()
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
>     (m,s) <- newMailbox
>     spawnReading s b
>     return m
>
> -- | fork a looping computation which starts immediately. Equivalent to
> -- launching a @Behavior ()@ and another 'Behavior' that sends an infinite stream of
> -- ()s to the former.
> spawn_ :: (MonadIO m)=> Behavior () -> m ()
> spawn_ = liftIO . void . forkIO . runBehavior_  
