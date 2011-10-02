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
>     , received
>     -- ** Spawning actors
>     {- | 
>     The 'spawn' function will be sufficient for forking actors in most cases,
>     but launching mutually-communicating actors presents a problem.
>     .
>     In cases where a 'Behavior' needs access to its own 'Mailbox' or that of 
>     an actor that must be forked later, the 'MonadFix' instance should be
>     used. GHC\'s \"Recursive Do\" make this especially easy:
>     .
>     > {-# LANGUAGE DoRec #-}
>     > beh = Behavior $ do
>     >     i <- received
>     >     rec b1 <- spawn (senderTo b2)
>     >         b2 <- spawn (senderTo b1)
>     >         b3 <- spawn (senderTo b3)
>     >     abort
>     -}
>     , spawn
>     , spawn_
>     , spawnReading
>     -- ** Aborting an actor computation
>     , abort
>
>     -- * Utility functions
>     , runBehavior_
>     , runBehavior 
>
>     -- * Useful predefined @Behavior@s
>     , printB
>     , putStrB
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

TODO
-----
    - try out an instance for Monoid for Behavior
        (some actor model implementations keep a message in the mailbox
         (whatever that means) when it falls through all case statements. this is
         kind of like the situation of a do pattern-match failure, thus a monoid
         that resumes on that input makes sense. Alternative sort of works this
         way)
    - use 'printB' instead of Chans in tree test
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
    - export some more useful Actors and global thingies
        - 'loop' which keeps consuming (is this provided by a class?)
        - function returning an actor to "load balance" inputs over multiple
          actors
        - an actor that sends a random stream?
        - a pre-declared Mailbox for IO?
    - provide an "adapter" for amazon SQS, allowing truly distributed message
      passing




CHAN TYPES
==========

> -- | One can 'send' a messages to a @Mailbox@ where it will be processed by an
> -- actor\'s defined 'Behavior'
> newtype Mailbox a = Mailbox { inChan :: InChan a }
>       deriving (Contravariant)
>
> -- internal:
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




ACTIONS
=======

Functionality is based on our underlying type classes, but users shouldn't need
to import a bunch of libraries to get basic Behavior building functionality:

> -- | Aborts an Actor computation:
> -- 
> -- > abort = mzero
> abort :: Action i a
> abort = mzero


> -- | Return the message received to start this 'Action' block. /N.B/ the value
> -- returned here does not change between calls in the same 'Action'.
> --
> -- > received = ask
> received :: Action i i
> received = ask


> -- | Send a message asynchronously. This can be used to send messages to other
> -- Actors via a 'Mailbox', or used as a means of output from the Actor system
> -- to IO.
> -- .
> -- > send b = liftIO . writeChan b
> send :: (MonadIO m, SplitChan c x)=> c a -> a -> m ()
> send b = liftIO . writeChan b



FORKING AND RUNNING ACTORS:
===========================


> -- | Like 'spawn' but allows one to specify explicitly the channel from which
> -- an actor should take its input.
> spawnReading :: (MonadIO m, SplitChan x c)=> c i -> Behavior i -> m ()
> spawnReading str = liftIO . void . forkIO . actorRunner 
>     where actorRunner b =
>               readChan str >>= runBehaviorStep b >>= F.mapM_ actorRunner


RUNNING ACTORS
--------------

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

> -- | Fork an 'actor' performing the specified 'Behavior'. /N.B./ an actor 
> -- begins execution of its 'headBehavior' only after a mesage has been 
> -- received. See 'spawn_'.
> spawn :: (MonadIO m)=> Behavior i -> m (Mailbox i)
> spawn b = do
>     (m,s) <- liftIO newSplitChan
>     spawnReading s b
>     return m
>
> -- | Fork a looping computation which starts immediately. Equivalent to
> -- launching a @Behavior ()@ and another 'Behavior' that sends an infinite stream of
> -- ()s to the former\'s 'Mailbox'.
> spawn_ :: (MonadIO m)=> Behavior () -> m ()
> spawn_ = liftIO . void . forkIO . runBehavior_  



USEFUL GENERAL BEHAVIORS
========================

> -- | Prints all messages to STDOUT in the order they are received, optionally 
> -- 'abort'-ing after @n@ inputs are 'received'.
> --
> -- > printB = contramap (unlines . return . show) . putStrB
> printB :: (Show s, Num n)=> Maybe n -> Behavior s
> printB = contramap (unlines . return . show) . putStrB

> -- | similar to 'printB', but does 'putStr' on input Strings it receives
> -- rather than printing each on a new line.
> putStrB :: (Num n)=> Maybe n -> Behavior String
> putStrB mn = Behavior $ do
>     guard $ maybe True (/=0) mn
>     s <- received
>     liftIO $ putStr s
>     return $ putStrB $ fmap (subtract 1) mn
