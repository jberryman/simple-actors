> {-# LANGUAGE GeneralizedNewtypeDeriving, MultiParamTypeClasses, TypeFamilies, TypeOperators #-}

This module exports a simple, idiomatic implementation of the Actor Model.

> module Control.Concurrent.Actors (
>
>     {- | 
>     Here we demonstrate a binary tree of actors that supports concurrent
>     insert and query operations:
>      
>     > import Control.Concurrent.Actors
>     > import Control.Applicative
>     > import Control.Concurrent.MVar
>     > 
>     > -- the actor equivalent of a Nil leaf node:
>     > nil :: Behavior Operation
>     > nil = Receive $ do
>     >     (Query _ var) <- received 
>     >     send var False -- signal Int is not present in tree
>     >     return nil     -- await next message
>     > 
>     >    <|> do          -- else, Insert received
>     >     l <- spawn nil -- spawn child nodes
>     >     r <- spawn nil
>     >     branch l r . val <$> received  -- create branch from inserted val
>     >     
>     > -- a branch node with a value 'v' and two children
>     > branch :: Node -> Node -> Int -> Behavior Operation    
>     > branch l r v = loop where
>     >     loop = Receive $ do
>     >         m <- received 
>     >         case compare (val m) v of
>     >              LT -> send l m
>     >              GT -> send r m
>     >              EQ -> case m of -- signal Int present in tree:
>     >                         (Query _ var) -> send var True
>     >                         _             -> return ()
>     >         return loop
>     > 
>     > type Node = Mailbox Operation
>     > 
>     > -- operations supported by the network:
>     > data Operation = Insert { val :: Int }
>     >                | Query { val :: Int
>     >                        , sigVar :: MVar Bool }
>     > 
>     > insert :: Node -> Int -> IO ()
>     > insert t = send t . Insert
>     > 
>     > -- MVar is in the 'SplitChan' class so actors can 'send' to it:
>     > query :: Node -> Int -> IO Bool
>     > query t a = do
>     >     v <- newEmptyMVar
>     >     send t (Query a v)
>     >     takeMVar v
>     
>     You can use the tree defined above in GHCi:
>     
>     >>> :l TreeExample.hs 
>     Ok
>     >>> t <- spawn nil
>     >>> query t 7
>     False
>     >>> insert t 7
>     >>> query t 7
>     True
>
>     -}
>
>     -- * Actor Behaviors
>       Action()
>     , Behavior(..)
>     -- ** Composing and Transforming Behaviors
>     , (<.|>)
>
>     -- * Available actions
>     -- ** Message passing
>     , Mailbox()
>     , send , send' , (<->)
>     , received
>     , guardReceived
>     -- ** Spawning actors
>     , Sources(), Joined
>     , Units
>   --, (:-:)(..)
>     , spawn
>     -- *** Mailboxes and scoping
>     {- | 
>     Straightforward use of the 'spawn' function will be sufficient for
>     forking actors in most cases, but launching mutually-communicating actors
>     presents a problem.
>      
>     In cases where a 'Behavior' needs access to its own 'Mailbox' or that of 
>     an actor that must be forked later, the 'MonadFix' instance should be
>     used. GHC\'s \"Recursive Do\" notation make this especially easy:
>      
>     > {-# LANGUAGE DoRec #-}
>     > beh = Receive $ do
>     >     i <- received
>     >     -- similar to the scoping in a "let" block:
>     >     rec b1 <- spawn (senderTo b2)
>     >         b2 <- spawn (senderTo b1)
>     >         b3 <- spawn (senderTo b3)
>     >     -- send initial messages to actors spawned above:
>     >     send b3 i
>     >     send b2 "first"
>     >     yield
>
>     -}
>
>     -- ** Building an actor computation
>     {- | 
>     An actor computation can be halted immediately by calling 'yield',
>     a synonym for 'mzero'. When an 'Action' calling @yield@ is composed with
>     another using @\<|\>@ the second takes over processing the /same/ input
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
>     >   <|> do i <- received -- same as the 'i' above
>     >          send c $ "TENTH INPUT: "++i
>     >          return (foo c 0)
>
>     The @Monoid@ instance for 'Behavior' works on the same principle.
>     -}
>     , yield
>     , receive
>
>     -- ** Composing and Transforming Mailboxes
>     {- |
>     We offer some operations to split and combine 'Mailbox'es of sum and
>     product types. 
>     -}
>     , coproductMb
>     , productMb
>     , zipMb
>     , faninMb
>     , fanoutMb
>
>     -- * Utility functions
>     {- | 
>     These are useful for debugging 'Behavior's
>     -}
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
> import Control.Applicative
> import Control.Monad.Reader(ask)
> import qualified Data.Foldable as F
> import Control.Monad.IO.Class
> import Control.Concurrent(forkIO)
> import Data.Monoid
> import Control.Arrow((***),(&&&),(|||))
>
> -- from the contravariant package 
> import Data.Functor.Contravariant
> -- from the chan-split package
> import Control.Concurrent.Chan.Split
> -- internal:
> import Control.Concurrent.Actors.Behavior




TODO
-----

0.4
    - allow destructuring using UndecidableInstances (see mockup) on spawn, allowing for new, awesome synchronization semantics!
        - also handle sums with a new (:-:) constructor on LHS of (<-)?
        - instance for N-tuples as well for LHS and RHS?
        - how does it fit in with what our Reducer semantics will be?
    - also subsume spawn_ into our new 'spawn' with a Running/Go tag on LHS of (<-)
        - how would that work with: (Go, Mailbox a) <- spawn b -- where b :: ((), a)
        - ad re-write rule for spawn :: Behavior () -> m Go, to be old 'spawn_'
    - make that also work with Behaviors of arbitrary input types using new GHC generics?
    - use :-: type in productMb, as well (instead of (,)), give it record names: unleft/coleft
    - fix homepage
    - performance tuning / benchmarking:
        + look at interface file: ghc -ddump-hi Control/Concurrent/Actors.hs -O -c
        + remove current PRAGMA
        - close browser and everything, do a fake quick benchmark to get clock info
        - be more controlled about the source lists (do once before defaultMain), use 'evaluate'
        - run with +RTS -s and make sure everything is 0
        - see if case-based nil is better
        - try storing the same chan (observable sharing) in each node, and use for streaming 
           send an MVar with messages for the query operation
        - get accurate baseline comparison between actors and set
        - use INLINABLE
        - test again with SPECIALIZE instead
        - try adding INLINE to all with higher-order args (or higher-order newtype wrappers)
           and make sure our LHS looks good for inlining
        - specialize `Action i (Behavior i)` or allow lots of unfolding... ? Optimize those loops, somehow. Rewrite rules?
        - take a look at threadscope for random tree test
        - look at "let floating" and INLINEABLE to get functions with "fully-applied (syntactically) LHS"
        - compare with previous version (cp to /tmp to use previous version)


Later:
    - get complete code coverage into simple test module
    - interesting solution to exit detection: 
        http://en.wikipedia.org/wiki/Huang%27s_algorithm
    - dynamically-bounded chans, based on number of writers to control
      producer/consumer issues? Possibly add more goodies to chan-split
          see: http://hackage.haskell.org/package/stm-chans
    - look at what Functor/Contravariant for read/write ends, and corresponding
      natural transformations those allow suggest about limits of Actor model
      and investigate inverse of Actors (Reducers?)
    - create an experimental Collectors sub-module
    - investigate ways of positively influencing thread scheduling based on
       actor work agenda?
    - export some more useful Actors and global thingies
        - 'loop' which keeps consuming (is this provided by a class?)
        - function returning an actor to "load balance" inputs over multiple
          actors
        - an actor that sends a random stream?
        - a pre-declared Mailbox for IO?

 Eventually:
    - some sort of exception handling technique (using actors?)
    - abilty to launch an actor that automatically "replicates" if its chan needs more
       consumers. This should probably be restricted to an `Action i ()` that we
       repeat.
    - can we automatically throttle producers on an Actor system level,
      optimizing message flow with some algorithm?
    - provide an "adapter" for amazon SQS, allowing truly distributed message
      passing
    - investigate erlang-style selective receive (using Alternative?)
    - consider: combining TChans, where values are popped off when available,
      for chan-split?
    - look at ways we can represent network IO as channels to interface with
      this. E.g:
        - https://github.com/ztellman/aleph
        - http://akka.io/ (scala remote actors lib)
        - http://www.zeromq.org/intro:read-the-manual
        - interface to amazon SQS
        - http://msgpack.org/ 
        - "shared memory" approaches?
        - cloudhaskell, haskell-mpi, etc. see: 
            http://stackoverflow.com/questions/8362998/distributed-haskell-state-of-the-art-in-2011
    -Behavior -> enumeratee package translator (and vice versa)
        (maybe letting us use useful enumerators)
     ...also now pipes, conduits, etc. etc.

     - study ambient/join/fusion calculi for clues as to where it's really at


CHAN TYPES
==========

By defining our Mailbox as the bare "send" operation we get a very convenient
way of defining contravariant instance, without all the overhead we had before,
while ALSO now supporting some great natural transformations on Mailboxes &
Messages.

We use this newtype to get 'Contravariant' for free, possibly revealing other
insights:

> type Sender a = Op (IO ()) a
>
> mailbox :: (a -> IO ()) -> Mailbox a
> mailbox = Mailbox . Op
>
> runMailbox :: Mailbox a -> a -> IO ()
> runMailbox = getOp . sender
>
> mkMailbox :: InChan a -> Mailbox a
> mkMailbox = mailbox . writeChan
>
> mkMessages :: OutChan a -> Messages a
> mkMessages = Messages . readChan
>
> -- | One can 'send' a messages to a @Mailbox@ where it will be processed
> -- according to an actor\'s defined 'Behavior'
> --
> -- > type Joined (Mailbox a) = a
> newtype Mailbox a = Mailbox { sender :: Sender a }
>       deriving (Contravariant)

We don't need to expose this thanks to the miracle of MonadFix and recursive do,
but this can be generated via the NewSplitChan class below if the user imports
the library:

> newtype Messages a = Messages { readMsg :: IO a }
>       deriving (Functor) 
>
> -- Not sure how to derive this or if possible:
> instance SplitChan Mailbox Messages where
>     readChan = readMsg
>     writeChan = runMailbox
>
> instance NewSplitChan Mailbox Messages where
>     newSplitChan = (mkMailbox *** mkMessages) `fmap` newSplitChan


For Mailboxes we can define all transformations associated with Cartesian and 
CoCartesian (from 'categories') but where the category is Dual (->), i.e. the
order of the transformation is flipped.

I don't know if/how these precisely fit into an existing class, but for now here
are a handful of useful combinators:

> coproductMb :: Mailbox a -> Mailbox b -> Mailbox (Either a b) 
> coproductMb m1 m2 = mailbox $ either (writeChan m1) (writeChan m2)
>
> zipMb :: Mailbox a -> Mailbox b -> Mailbox (a,b) 
> zipMb m1 m2 = mailbox $ \(a,b) -> writeChan m1 a >> writeChan m2 b
>

The naming here doesn't make much sense now that these are general. Keep for 
now and hope we can deprecate in favor of functionality in one of E.K.'s 
libs?

> -- | > productMb = contramap Left &&& contramap Right
> productMb :: Contravariant f => f (Either a b) -> (f a, f b)
> productMb = contramap Left &&& contramap Right
>
> -- | > faninMb f g = contramap (f ||| g)
> faninMb :: Contravariant f => (b -> a) -> (c -> a) -> f a -> f (Either b c)
> faninMb f g = contramap (f ||| g)
>
> -- | > fanoutMb f g = contramap (f &&& g)
> fanoutMb :: Contravariant f=> (a -> b) -> (a -> c) -> f (b,c) -> f a
> fanoutMb f g = contramap (f &&& g)




ACTIONS
=======

Functionality is based on our underlying type classes, but users shouldn't need
to import a bunch of libraries to get basic Behavior building functionality.

> infixl 3 <.|>
>
> -- | Sequence two @Behavior@s. After the first 'yield's the second takes over,
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
>
> -- | Useful to make defining a continuing Behavior more readable as a
> -- \"receive block\", e.g.
> --
> -- > pairUp out = Receive $ do
> -- >     a <- received
> -- >     receive $ do
> -- >         b <- received
> -- >         send out (b,a)
> -- >         return (pairUp out)
> --
> -- Defined as: 
> --
> -- > receive = return . Receive
> receive :: Action i (Behavior i) -> Action i (Behavior i)
> receive = return . Receive

> -- | Return the message received to start this 'Action' block. /N.B/ the value
> -- returned here does not change between calls in the same 'Action'.
> --
> -- > received = ask
> received :: Action i i
> received = ask

> -- | Return 'received' message matching predicate, otherwise 'yield'.
> --
> -- > guardReceived p = ask >>= \i-> guard (p i) >> return i
> guardReceived :: (i -> Bool) -> Action i i
> guardReceived p = ask >>= \i-> guard (p i) >> return i

> -- | Send a message asynchronously. This can be used to send messages to other
> -- Actors via a 'Mailbox', or used as a means of output from the Actor system
> -- to IO since the function is polymorphic in 'SplitChan'.
> --  
> -- > send b = liftIO . writeChan b
> send :: (MonadIO m, SplitChan c x)=> c a -> a -> m ()
> send b = liftIO . writeChan b

> -- | A strict 'send':
> --
> -- > send' b a = a `seq` send b a
> send' :: (MonadIO m, SplitChan c x)=> c a -> a -> m ()
> send' b a = a `seq` send b a

> infixr 1 <->
>
> -- | Like 'send' but supports chaining sends by returning the Mailbox.
> -- Convenient for initializing an Actor with its first input after spawning,
> -- e.g.
> --
> -- >     do mb <- 0 <-> spawn foo
> (<->) :: (MonadIO m, SplitChan c x)=> a -> m (c a) -> m (c a)
> a <-> mmb = mmb >>= \mb-> send mb a >> return mb




FORKING AND RUNNING ACTORS:
===========================

The strict Actor Model is limited in expressiveness, in that it doesn't allow
for a method of synchronization, e.g. we cannot have an actor that pairs up
incoming messages from two different channels. I think this leads to nonsense
like "selective receive" in Erlang (disclaimer: IANA erlang-xpert).

I've realized that I can keep all the nice semantics of actors (i.e. this
change doesn't affect Behaviors) , while supporting synchronization and
simplifying the API all at the same time! This method is inspired by the "join
calculus", and I'm sure this isn't a new idea.

To support this elegantly in the API, we define a class with associated type,
and make 'spawn' the method. This allows the pattern of joins to be determined
polymorphically based on users' pattern match!

    NOTE: My original goal was to use GHC.Generic to support arbitrary joins on
    any Generic a=> Behavior a ...but it wasn't coming together. Let me know
    if you can figure it out.

> -- | We extend the actor model to support joining (or synchronizing) multiple
> -- 'Mailbox'es to a single 'Behavior' input type, using a new class with an
> -- associated type. Functionality is best explained by example:
> --
> -- Spawn an actor returning it's 'Mailbox', and send it its first message:
> -- 
> -- > sumTuple :: Behavior (Int, Int)
> -- >
> -- > do b <- spawn sumTuple
> -- >    send b (4, 1) 
> -- >    ...
> --
> -- But now we would like our @sumTuple@ actor to receive each number from a different 
> -- concurrent actor:
> --
> -- > do (b1, b2) <- spawn sumTuple
> -- >    b3 <- spawn (multipliesBy2AndSendsTo b1)
> -- >    send b3 2
> -- >    send b2 1
> -- >    ...
> --
> -- Lastly spawn an actor that starts immediately on an infinite supply of 'Units',
> -- and supplies an endless stream of @Int@s to @sumTuple@
> --
> -- > do (b1, b2) <- spawn sumTuple
> -- >    Units <- spawn (sendsIntsTo b2)
> -- >    send b1 4
> -- >    ...
> class Sources s where
>     type Joined s :: *
>     newJoinedChan :: IO (s, Messages (Joined s)) -- private

Spawn uses un-exported newJoinedChan where we used newSplitChan previously:

> -- | Fork an actor performing the specified 'Behavior'. /N.B./ an actor
> -- begins execution of its 'headBehavior' only after a message becomes
> -- available to process; for sending an initial message to an actor right
> -- after 'spawn'ing it, ('<|>') can be convenient.
> spawn :: (MonadIO m, Sources s)=> Behavior (Joined s) -> m s
> spawn b = liftIO $ do
>     (srcs, msgs) <- newJoinedChan
>     let runner b' = readChan msgs >>= runBehaviorStep b' >>= F.mapM_ runner
>     void $ forkIO (runner b)
>     return srcs

...and our instance for Mailbox completes previous simple spawn functionality:

> instance Sources (Mailbox a) where
>     type Joined (Mailbox a) = a
>     newJoinedChan = newSplitChan

By adding an instance for (,) synchronization and wonderful new things become
possible!

> instance (Sources a, Sources b)=> Sources (a,b) where
>     type Joined (a,b) = (Joined a, Joined b)
>     newJoinedChan = do
>         (sa, ma) <- newJoinedChan
>         (sb, mb) <- newJoinedChan
>         let m' = Messages $ liftM2 (,) (readMsg ma) (readMsg mb)
>         return ((sa,sb), m')

We'll add instances up to 7-tuples, since that seems to be standard, but people
can use nested tuples:

> instance (Sources a, Sources b, Sources c, Sources d, Sources e, Sources f, Sources g)=> Sources (a,b,c,d,e,f,g) where
>     type Joined (a,b,c,d,e,f,g) = (Joined a, Joined b,Joined c,Joined d,Joined e,Joined f,Joined g)
>     newJoinedChan = do
>         (sa, ma) <- newJoinedChan
>         (sb, mb) <- newJoinedChan
>         (sc, mc) <- newJoinedChan
>         (sd, md) <- newJoinedChan
>         (se, me) <- newJoinedChan
>         (sf, mf) <- newJoinedChan
>         (sg, mg) <- newJoinedChan
>         let m' = Messages $ (,,,,,,) <$> readMsg ma <*> readMsg mb <*> readMsg mc <*> readMsg md <*> readMsg me <*> readMsg mf <*> readMsg mg 
>         return ((sa,sb,sc,sd,se,sf,sg), m')
>
> instance (Sources a, Sources b, Sources c, Sources d, Sources e, Sources f)=> Sources (a,b,c,d,e,f) where
>     type Joined (a,b,c,d,e,f) = (Joined a, Joined b,Joined c,Joined d,Joined e,Joined f)
>     newJoinedChan = do
>         (sa, ma) <- newJoinedChan
>         (sb, mb) <- newJoinedChan
>         (sc, mc) <- newJoinedChan
>         (sd, md) <- newJoinedChan
>         (se, me) <- newJoinedChan
>         (sf, mf) <- newJoinedChan
>         let m' = Messages $ (,,,,,) <$> readMsg ma <*> readMsg mb <*> readMsg mc <*> readMsg md <*> readMsg me <*> readMsg mf
>         return ((sa,sb,sc,sd,se,sf), m')
>
> instance (Sources a, Sources b, Sources c, Sources d, Sources e)=> Sources (a,b,c,d,e) where
>     type Joined (a,b,c,d,e) = (Joined a, Joined b,Joined c,Joined d,Joined e)
>     newJoinedChan = do
>         (sa, ma) <- newJoinedChan
>         (sb, mb) <- newJoinedChan
>         (sc, mc) <- newJoinedChan
>         (sd, md) <- newJoinedChan
>         (se, me) <- newJoinedChan
>         let m' = Messages $ (,,,,) <$> readMsg ma <*> readMsg mb <*> readMsg mc <*> readMsg md <*> readMsg me
>         return ((sa,sb,sc,sd,se), m')
>
> instance (Sources a, Sources b, Sources c, Sources d)=> Sources (a,b,c,d) where
>     type Joined (a,b,c,d) = (Joined a, Joined b,Joined c,Joined d)
>     newJoinedChan = do
>         (sa, ma) <- newJoinedChan
>         (sb, mb) <- newJoinedChan
>         (sc, mc) <- newJoinedChan
>         (sd, md) <- newJoinedChan
>         let m' = Messages $ (,,,) <$> readMsg ma <*> readMsg mb <*> readMsg mc <*> readMsg md 
>         return ((sa,sb,sc,sd), m')
>
> instance (Sources a, Sources b, Sources c)=> Sources (a,b,c) where
>     type Joined (a,b,c) = (Joined a, Joined b,Joined c)
>     newJoinedChan = do
>         (sa, ma) <- newJoinedChan
>         (sb, mb) <- newJoinedChan
>         (sc, mc) <- newJoinedChan
>         let m' = Messages $ (,,) <$> readMsg ma <*> readMsg mb <*> readMsg mc 
>         return ((sa,sb,sc), m')


I give up for now on defining an instance for sums. This probably requires a
different formulation for class

    ...and we also support Either as a source, since this is the only way to get a joined
    product of sums; otherwise users could just use 'productMb', a pure operation.

    > -- | > type Joined (a :-: b) = Either (Joined a) (Joined b)
    > --
    > -- A product of 'Sources' corresponding to a @Behavior (Either a b)@. Allows
    > -- 'spawn'-ing a @Behavior@  which receives a sum of perhaps-'Joined' products.
    > --
    > -- See also: 'productMb'
    > data a :-: b = (:-:) { sourceLeft :: a
    >                      , sourceRight :: b }
    >
    > instance (Sources a, Sources b)=> Sources (a :-: b) where
    >     type Joined (a :-: b) = Either (Joined a) (Joined b)
    >     --newJoinedChan :: IO (a :-: b, Messages (Either (Joined a) (Joined b)))
    >     newJoinedChan = do
    >         (src, msgs) <- newSplitChan
    >         let (s1, s2) = productMb src
    >         return (decompose s1 :-: decompose s2, msgs)

    class Sources s where
        type Joined s :: *
        newJoinedChan :: IO (s, Messages (Joined s))
        decomp :: Mailbox (a,b) -> (Mailbox a, Mailbox b)
        decomp :: Mailbox a -> Mailbox a
        decomp :: Mailbox (Either a b) -> (Mailbox a :-: Mailbox b)


We can subsume the old 'spawn_' functionality in our class as well, and imagine
returning an infinite source of ()s:

> -- | > type Joined Units = ()
> --
> -- Like a 'Mailbox' full of an endless supply of @()@s. Allows 'spawn'-ing
> -- a @Behavior ()@ that starts immediately and loops until it 'yield'-s, e.g.
> -- 
> -- > do Units <- spawn startsImmediately -- :: Behavior ()
> data Units = Units
>
> instance Sources Units where
>     type Joined Units = ()
>     newJoinedChan = 
>         return (Units, Messages $ return ())

Replace polymorphic craziness with old spawn_ function, when we can:

> {-# RULES "spawn_" spawn = spawn_  #-}
> spawn_ :: (MonadIO m)=> Behavior () -> m Units
> spawn_ = liftIO . (Units <$) . forkIO . runBehavior_


    NOTE: spawnReading removed in 0.4, since it was unused (by me), exposed
    confusing implementation details, supports e.g. launching an actor on a
    bounded channel which violates the Model, and doesn't provide an effective
    way to do much cool stuff like reading from a network socket.

    Instead I guess we should expose enough internals in a separate module to
    support future cool stuff.



RUNNING ACTORS
--------------

These work in IO, returning () when the actor finishes with done/mzero:

> -- | Run a @Behavior ()@ in the main thread, returning when the computation
> -- exits.
> runBehavior_ :: Behavior () -> IO ()
> runBehavior_ b = runBehavior b $ repeat ()
>
> -- | run a 'Behavior' in the IO monad, taking its \"messages\" from the list.
> runBehavior :: Behavior a -> [a] -> IO ()
> runBehavior b (a:as) = runBehaviorStep b a >>= F.mapM_ (`runBehavior` as)
> runBehavior _ _      = return ()




USEFUL GENERAL BEHAVIORS
========================

> -- | Prints all messages to STDOUT in the order they are received,
> -- 'yield'-ing /immediately/ after @n@ inputs are printed.
> printB :: (Show s, Eq n, Num n)=> n -> Behavior s
> printB = contramap (unlines . return . show) . putStrB

We want to yield right after printing the last input to print. This lets us
compose with signalB for instance:

    write5ThenExit = putStrB 5 `mappend` signalB c

and the above will signal as soon as it has printed the last message. If we try
to define this in a more traditional recursive way the signal above would only
happen as soon as the sixth message was received.

For now we allow negative

> -- | Like 'printB' but using @putStr@.
> putStrB :: (Eq n, Num n)=> n -> Behavior String
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
> -- compositions when one wants to ignore the leftover 'yield'ed message.
> --
> -- > constB = Receive . return
> constB :: Behavior i -> Behavior i
> constB = Receive . return
