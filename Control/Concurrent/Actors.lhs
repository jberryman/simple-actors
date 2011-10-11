> {-# LANGUAGE CPP, GeneralizedNewtypeDeriving, MultiParamTypeClasses #-}

This module exports a simple, idiomatic implementation of the Actor Model.

> module Control.Concurrent.Actors (
>     {- | 
>       EXAMPLES AND USAGE
>     -}
>
>     -- * Actor Behaviors
>       Action()
>     , Behavior(..)
>     -- ** Composing Behaviors
>     , (<.|>)
>
>     -- * Available actions
>     -- ** Message passing
>     , Mailbox()
>     , send
>     , received
>     , guardReceived
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
>     > beh = Receive $ do
>     >     i <- received
>     >     -- similar to the scoping in a "let" block:
>     >     rec b1 <- spawn (senderTo b2)
>     >         b2 <- spawn (senderTo b1)
>     >         b3 <- spawn (senderTo b3)
>     >     -- send initial messages to actors spawned above:
>     >     send b3 i
>     >     send "first" b2
>     >     yield
>     -}
>     , spawn
>     , spawn_
>     , spawnReading
>     -- ** Exiting an actor computation
>     {- | 
>     An actor computation can be halted immediately by calling 'yield' which is
>     a synonym for 'mzero'. When an 'Action' calling @yield@ is composed with
>     another using @<|>@ the second takes over processing the /same/ input
>     which the former @yield@-ed on.
>
>     Here is an example of a computation using 'guard' which returns @mzero@ if
>     the test is false:
>
>     > foo c n = Receive $ 
>     >       do i <- received
>     >          guard (n<10)
>     >          send c i
>     >          return (foo c $ n+1)
>     >
>     >   <|> do i <- received -- same as 'i' above
>     >          send c $ "TENTH INPUT: "++i
>     >          return (foo c 0)
>
>     The behavior for the @Monoid@ instance for 'Behavior' works on the same
>     principle.
>     -}
>     , yield
>
>     -- * Utility functions
>     , runBehavior_
>     , runBehavior 
>
>     -- * Useful predefined @Behavior@s
>     , printB
>     , putStrB
>     , signalB
>     , constB
>
>     ) where
>
> import Control.Monad
> import Control.Monad.Reader(ask)
> import qualified Data.Foldable as F
> import Control.Monad.IO.Class
> import Control.Concurrent(forkIO)
> import Data.Monoid
>
> -- from the contravariant package 
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
    - add receive = return . Receive
    - some more involved / realistic tests
        - get complete code coverage into simple test module
        - binary tree
    - clean up function docs (refs to locks, etc.)
        - example
    - release 0.1.0 !

 0.2.0:
    - performance testing:
        - take a look at threadscope for random tree test
    - interesting: http://en.wikipedia.org/wiki/Huang%27s_algorithm
    - better method for waiting for threads to complete. should probbly use
       actor message passing
    - look into whether we should use Text lib instead of strings?
      OverloadedStrings?
        -import Data.String, make polymorphic over IsString
        -test if this lets us use it in importing module w/ OverloadedStrings
        extension
    - structured declarative and unit tests
    - Performance testing:
        - test performance vs. straight Chans, etc.
        - test out overhead of our various locks, especially difference if we
          scrap the snederLockMutex
    - some sort of exception handling technique via Actors
        (look at enumerator package)
    - investigate ways of positively influencing thread scheduling based on
       actor work agenda 
    - strict send' function
    -Behavior -> enumeratee package translator (and vice versa)
        (maybe letting us use useful enumerators)
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
to import a bunch of libraries to get basic Behavior building functionality.

> infixl 3 <.|>

> -- | Sequence two Behaviors. After the first 'yield's the second takes over,
> -- discarding the message the former was processing. See also the 'Monoid'
> -- instance for @Behavior@.
> -- 
> -- > b <.|> b' = b `mappend` constB b'
> (<.|>) :: Behavior i -> Behavior i -> Behavior i
> b <.|> b' = b `mappend` constB b'

The 'yield' function is so named because it is "relinquishing control", i.e. I
think the name reminds of the functionality of <|> and mappend (the last input
is passed along) and also has the meaning "quit".

Its similarity (or not) to the 'enumerator' function of the same same may be a
source of confusion (or the opposite)... I'm not sure.

> -- | Immediately give up processing an input, perhaps relinquishing the input
> -- to an 'Alternative' computation or exiting the actor.
> -- 
> -- > yield = mzero
> yield :: Action i a
> yield = mzero


> -- | Return the message received to start this 'Action' block. /N.B/ the value
> -- returned here does not change between calls in the same 'Action'.
> --
> -- > received = ask
> received :: Action i i
> received = ask

> -- | Return received message matching predicate, otherwise 'yield'.
> --
> -- > guardReceived p = ask >>= \i-> guard (p i) >> return i
> guardReceived :: (i -> Bool) -> Action i i
> guardReceived p = ask >>= \i-> guard (p i) >> return i

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

> -- | Prints all messages to STDOUT in the order they are received,
> -- 'yield'-ing /immediately/ after @n@ inputs are printed.
> printB :: (Show s, Num n)=> n -> Behavior s
> printB = contramap (unlines . return . show) . putStrB

We want to yield right after printing the last input to print. This lets us
compose with signalB for instance:

    write5ThenExit = putStrB 5 `mappend` signalB c

and the above will signal as soon as it has printed the last message. If we try
to define this in a more traditional recursive way the signal above would only
happen as soon as the sixth message was received.

For now we allow negative

> -- | Like 'printB' but using @putStr@.
> putStrB :: (Num n)=> n -> Behavior String
> putStrB 0 = mempty --special case when called directly w/ 0
> putStrB n = Receive $ do
>     s <- received
>     liftIO $ putStr s
>     guard (n /= 1)
>     return $ putStrB (n-1)

> -- | Sends a @()@ to the passed chan. This is useful with 'mappend' for
> -- signalling the end of some other 'Behavior'.
> --
> -- > signalB c = Receive (send c () >> yield)
> signalB :: (SplitChan c x)=> c () -> Behavior i
> signalB c = Receive (send c () >> yield)

> -- | A @Behavior@ that discard its first input, returning the passed Behavior
> -- for processing subsequent inputs. Useful with 'Alternative' or 'Monoid'
> -- compositions when one wants to ignore the leftover input.
> --
> -- > constB = Receive . return
> constB :: Behavior i -> Behavior i
> constB = Receive . return
