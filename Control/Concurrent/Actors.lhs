> {-# LANGUAGE GeneralizedNewtypeDeriving, MultiParamTypeClasses #-}

This module exports a simple, idiomatic implementation of the Actor Model.

> module Control.Concurrent.Actors (
>
>     {- | 
>     Here we demonstrate a binary tree of actors that supports insert and query
>     operations:
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
>     {- | 
>     In the Actor Model, at each step an actor...
>     
>         - processes a single 'received' message
>         
>         - may 'spawn' new actors
>         
>         - may 'send' messages to other actors
>         
>         - 'return's the 'Behavior' for processing the /next/ message
>     
>     These actions take place within the @Action i@ monad, where @i@ is the type
>     of the input message the actor receives.
>     
>     /N.B.:/ the MonadIO instance here is an abstraction leak. An example of a
>     good use of 'liftIO' might be to give an @Action@ access to a source of
>     randomness.
>     -}
>       Action()
>     {- | 
>     An actor is created by 'spawn'ing a @Behavior@. Behaviors consist of a
>     composed 'Action' that is executed when a message is 'received' and
>     returns the @Behavior@ for processing the next input.
>     -}
>     , Behavior(..)
>     -- ** Composing Behaviors
>     , (<.|>)
>
>     -- * Available actions
>     -- ** Message passing
>     , Mailbox()
>     , send , send' , (<->)
>     , received
>     , guardReceived
>     -- ** Spawning actors
>     {- | 
>     The 'spawn' function will be sufficient for forking actors in most cases,
>     but launching mutually-communicating actors presents a problem.
>      
>     In cases where a 'Behavior' needs access to its own 'Mailbox' or that of 
>     an actor that must be forked later, the 'MonadFix' instance should be
>     used. GHC\'s \"Recursive Do\" make this especially easy:
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
>     >     send "first" b2
>     >     yield
>
>     -}
>
>     , spawn
>     , spawn_
>     , spawnReading
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
>     -- ** Transforming Mailboxes
>     {- |
>     We offer some operations to split and combine 'Mailbox'es of sum and
>     product types. Where these are defined polymorphically in terms of
>     'SplitChan' we were able to implement these operations using actors.
>     -}
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




TODO
-----
 0.3.0:
    - define natural transformation combinators (in IO unfortunately. ACTUALLY NO!) a.la.
      'categories' for Mailbox. So
        - :: Mailbox (a,b) -> (Mailbox a, Mailbox b)  -- unzip
                create two new chans. listen on first, then on second, send (a,b) out to arg chan, repeat
            NOT IMPLEMENTABLE WITH ACTORS?:
                META: this seems like an instance that exposes a limitation of actor model,
                  where we can probably only implement this using "selective receive"
                  which is really a way of hiding this flaw.
                  What happened to notion of Collectors?
                  This is not possible because inherently FUNCTORIAL 
                   (see Data.Functor.Adjunction, note on "unzip")
                  

     IMPLEMENTABLE WITHOUT IO, WITH DIFFERENT CHAN REPRESENTATION:
         newtype MailBox a = MailBox (a -> IO ())
                  
        - :: Mailbox a -> Mailbox b -> Mailbox (Either a b) -- coproduct
            IMPLEMENTABLE WITH ACTORS:
                spawn actor closed over mbA/B
                shuttle incoming messages to either as appropriate

            
        - :: Mailbox a -> Mailbox b -> Mailbox (a,b) -- zip, see Data.Functor.Adjunction
            IMPLEMENTABLE WITH ACTORS:
                spawn tuple actor, send a to mbA, b to mbB as tuples arrive

     IMPLEMENTABLE WITHOUT IO:
        - :: Mailbox (Either a b) -> (Mailbox a, Mailbox b) --product?
            IMPLEMENTABLE WITH PURE CONTRAVARIANT:
                foo mb = (contramap Left mb, contramap Right mb)

        INSPIRED BY Control.Category.*, etc. but with last reversed

        - (|||)-variant... codiag also useful
          :: (a -> c) -> (b -> c)-> (Mailbox c -> Mailbox (Either a b)) 
            IMPLEMENTABLE WITH PURE CONTRAVARIANT:
                foo f g = contramap (either f g) 
        - (&&&)-variant... diag also useful
          :: (a -> b) -> (a -> c) -> (Mailbox (b,c) -> Mailbox a)
            IMPLEMENTABLE WITH PURE CONTRAVARIANT:
                foo f g = contramap (\a-> (f a, f g))

        - idl variant, etc.
          :: Mailbox ((), a) -> Mailbox a

      PLAN W/R/T ABOVE AND CHAN SPLIT
        chan-split:
        - no longer depend on contravariant
        - copy portions of split-chan lib (see notes)
        - do some tests, e.g. GC properties
        
        simple-actors:
        - newtype MailBox a = MailBox { send :: a -> IO () }
        - newtype Messages a = Messages { receive :: IO a }
        - don't export constructors
        - define instances (see Op, Predicate, other defined types):
            - contravariant
            - Corepresentable (Value MailBox = IO (), etc.)
        - define any combinators above we don't get from instances


      put these in a separate sub-module, optionally import, mention how an
      extension to actor model or something

      ALSO: email Edward Kmett, curious what he thinks w/r/t these in IO. Any insights?
            trying to define these various natural transformations and 
            categorical creatures might be a great way of piecing out the
            real limitations of the Actor model, and how extensions might
            solve these.

      MORE NOTES ON SUBJECT:
          - somewhat interesting, at least in terms of naming, though I don't think MBs are adjunctions by any stretch:
             http://hackage.haskell.org/packages/archive/adjunctions/3.0/doc/html/Data-Functor-Adjunction.html
          - if we expose a Mailbox's original type, it can be Valued, CoIndexed, but NOT corepresentable, because we would need IO in corep
             http://hackage.haskell.org/packages/archive/representable-functors/2.0.2/doc/html/Data-Functor-Corepresentable.html#t:Value
          - what we've done w/ mailbox on both ends is identical to Yoneda Lemma?:
             http://hackage.haskell.org/packages/archive/kan-extensions/2.7/doc/html/Data-Functor-Yoneda-Contravariant.html
          - we can form all the contructions in cocartesian, but in reverse? 

    - performance testing:
        - take a look at threadscope for random tree test
        - get complete code coverage into simple test module
    - interesting solution to exit detection: 
        http://en.wikipedia.org/wiki/Huang%27s_algorithm
    - better method for waiting for threads to complete. should probably use
       actor message passing
    - look into whether we should use Text lib instead of strings?
      OverloadedStrings?
        -import Data.String, make polymorphic over IsString
        -test if this lets us use it in importing module w/ OverloadedStrings
        extension
    - structured declarative and unit tests
    - some sort of exception handling technique via Actors
        (look at enumerator package)

Later:
    - create an experimental Collectors sub-module
    - investigate ways of positively influencing thread scheduling based on
       actor work agenda?
    - export some more useful Actors and global thingies
        - 'loop' which keeps consuming (is this provided by a class?)
        - function returning an actor to "load balance" inputs over multiple
          actors
        - an actor that sends a random stream?
        - a pre-declared Mailbox for IO?

 Eventualy:
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


CHAN TYPES
==========

> -- | One can 'send' a messages to a @Mailbox@ where it will be processed
> -- according to an actor\'s defined 'Behavior'
> newtype Mailbox a = Mailbox { inChan :: InChan a }
>       deriving (Contravariant)
>

We don't need to expose this thanks to the miracle of MonadFix and recursive do,
but this can be generated via the NewSplitChan class below if the user imports
the library:

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


There isn't really a good abstraction for these AFAICS:

> divideMb :: Mailbox (a,b) -> (Mailbox a, Mailbox b)  
> addMb :: Mailbox a -> Mailbox b -> Mailbox (Either a b) --MORE DIFFICULT!




ACTIONS
=======

Functionality is based on our underlying type classes, but users shouldn't need
to import a bunch of libraries to get basic Behavior building functionality.

> infixl 3 <.|>

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
> -- to IO since the function is polymorphic.
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
> -- Convenient for initializing an Actor with its first input aftwer spawning,
> -- e.g.
> --
> -- >     do mb <- 0 <-> spawn foo
> (<->) :: (MonadIO m, SplitChan c x)=> a -> m (c a) -> m (c a)
> a <-> mmb = mmb >>= \mb-> send mb a >> return mb




FORKING AND RUNNING ACTORS:
===========================


> -- | Like 'spawn' but allows one to specify explicitly the channel from which
> -- an actor should take its input. Useful for extending the library to work
> -- over other channels.
> spawnReading :: (MonadIO m, SplitChan x c)=> c i -> Behavior i -> m ()
> spawnReading str = liftIO . void . forkIO . actorRunner 
>     where actorRunner b =
>               readChan str >>= runBehaviorStep b >>= F.mapM_ actorRunner


RUNNING ACTORS
--------------

These work in IO, returning () when the actor finishes with done/mzero:

> -- | Run a @Behavior ()@ in the main thread, returning when the computation
> -- exits.
> runBehavior_ :: Behavior () -> IO ()
> runBehavior_ b = runBehavior b [(),()..]
>
> -- | run a 'Behavior' in the IO monad, taking its \"messages\" from the list.
> runBehavior :: Behavior a -> [a] -> IO ()
> runBehavior b (a:as) = runBehaviorStep b a >>= F.mapM_ (`runBehavior` as)
> runBehavior _ _      = return ()



FORKING ACTORS
--------------

> -- | Fork an actor performing the specified 'Behavior'. /N.B./ an actor 
> -- begins execution of its 'headBehavior' only after a message has been 
> -- received; for sending an initial message to an actor right after 'spawn'ing
> -- it, ('\<|\>') can be convenient.
> --
> -- See also 'spawn_'.
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
