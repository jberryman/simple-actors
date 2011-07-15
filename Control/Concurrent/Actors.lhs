> {-# LANGUAGE CPP, GeneralizedNewtypeDeriving, ViewPatterns, DeriveFunctor #-}

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
>     , Mailbox
>     , ActorStream
>     , IOStream
>     -- ** Actor system output
>     , receive
>     , receiveList
>     -- * Running Actors
>     , MonadAction()
>     , forkActor
>     , forkActorUsing
>     , forkActor_
>     -- ** Running Actor computations in current IO thread
>     , runActorUsing
>     , runActor_
>     -- * Supporting classes
>     , module Data.Cofunctor 
>     ) where
>
> import Control.Monad
> import Control.Monad.IO.Class
> import Control.Monad.Trans.Maybe
> import Control.Concurrent.MVar
> import Control.Concurrent(forkIO)
> import Control.Applicative
>
> -- from the chan-split package
> import Control.Concurrent.Chan.Split
> import Data.Cofunctor




------

These macros are only provided by cabal unfortunately.... makes it difficult to
work with GHCi:

#if MIN_VERSION_base(4,3,0)

> import Control.Exception(assert,try,BlockedIndefinitelyOnMVar
>                         ,catches,Handler(..),SomeException,bracket,bracket_)
> 

#else

> import Control.Exception(assert,try,block,BlockedIndefinitelyOnMVar
>                         ,catches,Handler(..),SomeException,bracket,bracket_)
>
> mask_ :: IO a -> IO a
> mask_ = block
> 
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
    - MonadAction is wholly unnecessary, use MonadIO
    - figure out locking/sharing behavior of receiveList/receive and other IO
      functions
    - switch exception handling to use bracket and variants
    - testing

    - better documentation:
        - show implementation in docs when it reveals something
        - examples
        - explanations when useful

    - test performance of send blocking and not blocking
    - better exception handling with an eye for helping the GC

    - export some useful Actors:
        - 'loop' which keeps consuming
        - function returning an actor to "load balance" inputs over multiple
          actors
    - create an internal module allowing wrapping IO in Actor
        - use liftIO to do that




Here we define the Actor environment, similar to IO, in which we can launch new
Actors and send messages to Actors in scope. The implementation is hidden from
the user to enforce these restrictions.

> -- | The Actor encironment in which Actors can be spawned and sent messages
> newtype Action a = Action { action :: MaybeT IO a }
>                  deriving (Monad, Functor, Applicative, 
>                            Alternative, MonadPlus, MonadIO)
>
> runAction :: Action a -> IO (Maybe a)
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


An Actor_ is just an Actor that ignores its input. We provide some useful
functions for building and running such computations:

> -- | An Actor that discards its input
> type Actor_ = Actor ()
>
> -- | Continue with an Actor_ computation, lifting it into the current Actor
> -- input type
> --
> -- > continue_ = continue . cofmap (const ())
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
> data Mailbox i = Mailbox { 
>                      inChan :: InChan (Message i)
>                    , senderLockMutex :: Maybe SenderLockMutex 
>                    }
>
> -- | A stream of messages, received via a corresponding 'Mailbox', which can
> -- /only/ act as input for an 'Actor' computation
> data ActorStream o = ActorStream { 
>                            outChan :: OutChan (Message o)
>                          , senderLock :: SenderLock
>                          , forkLock :: ForkLock
>                          }
>
>
> unblockSenders, blockSenders, acquireStream, giveUpStream :: ActorStream o -> IO ()
>  -- TODO: IF THIS RAISES BlockedIndefinitelyOnMVar THEN A PREVIOUS CLEANUP
>  -- AFTER A FORK FAILED. WE SHOULD LOG THIS, AND THEN ASSUME CONTROL OF THE
>  -- STREAM (TEST IF THIS REASONING IS RIGHT)
> acquireStream = takeMVar . getFLock . forkLock
>  -- TODO: BlockedIndefinitelyOnMVar HERE ALSO MEANS SOMETHING WENT WRONG. LOG
>  -- when dEBUGGING 
> giveUpStream = flip putMVar () . getFLock . forkLock

>  -- TODO: BlockedIndefinitelyOnMVar in these SHOULD BE LOGGED:
> unblockSenders = flip putMVar () . getSLock . senderLock
> blockSenders = takeMVar . getSLock . senderLock 
>
> closeStream, openStream :: ActorStream o -> IO ()
>  -- TODO: use FINALLY HERE?
> closeStream str = blockSenders str >> giveUpStream str
> openStream str = acquireStream str >> unblockSenders str

    NOTE: we don't use a locking mechanism for IOStream for now, but may 
     put some kind of signalling mechanism in later. This would probably 
     have to use STM to be useful and avoid race conditions.


> -- | A stream of messages, received via a corresponding 'Mailbox', which can
> -- be freely read from only in the IO Monad.
> newtype IOStream o = IOStream { ioStream :: OutChan (Message o) 
>                               } deriving Functor


We use a system of locks to enforce these properties of the environment:

    1) Sends will block until there is an Actor processing the stream

    2) Attempting to fork on an ActorStream will block until no other Actor
        is processing the stream

    NOTE: currently 'send's to a Mailbox with a corresponding IOStream will
          never block. We should use an internal class to allow us to ditch the
          MVar wrapping for sends to IOStream.

SEND LOCKS
-----------

All the senders who want to send block on this mutex:

> newtype SenderLockMutex = SLM { getMutex :: MVar SenderLock }
>
> takeSenderLock :: SenderLockMutex -> IO SenderLock
>  -- TODO: BlockedIndefinitelyOnMVar HERE MEANS: the SenderLock was never
>  -- returned and we lost the game. Re-raise a more meaningful exception
> takeSenderLock = takeMVar . getMutex
>
> putSenderLock :: SenderLockMutex -> SenderLock -> IO ()
>  -- TODO: BlockedIndefinitelyOnMVar HERE MEANS: the (some?) SenderLock was
>  -- 'put' or never taken or aliens. We lost the game and should re-raise a
>  -- humbling appology
> putSenderLock = putMVar . getMutex

They then must readMVar here before writing to the Chan. This inner MVar is
copied in the corresponding ActorStream:

> newtype SenderLock = SL { getSLock :: MVar () }
>
> waitSenderLock :: SenderLock -> IO ()
>  -- TODO: BlockedIndefinitelyOnMVar HERE MEANS: (assuming we didn't do
>  -- something stupid like use any other function to get or put this MVar) that no
>  -- Actor will ever be working on the corresponding stream we're dealing with.
>  --     We want sends to a dead actor to raise an exception in the sending
>  -- actor. So... 
> waitSenderLock = readMVar . getSLock  -- take + put
>

We must use this double-lock to ensure that we can block senders without waiting
in line behind all the senders currently in the queue to do a 'take' on the
MVar.



FORK LOCKS
-----------

While an actor is reading from a stream it takes the () and when it finishes (or
dies with an exception) it returns it. Thus forks should block and queue fairly
on this:

> newtype ForkLock = FL { getFLock :: MVar () }

Property: if a fork operation raises a BlockedIndefinitelyOnMVar exception, it
means the lock wasn't returned. Explore how we should react in that case.


    HOW WE USE THE LOCKS
    --------------------

        newChanPair (ActorStream):
            ...
        forkActorOn:
            ...
        send:
            ...
        done (or exception handled):
            ...

        

The internal message type. The addition of an MVar allows for syncronous message
passing between Actors:

> newtype Message i = Message { message :: (Maybe SyncToken, i) } 
>                   deriving Functor
> newtype SyncToken = ST { syncToken :: MVar () }
>
> sync, awaitSync :: SyncToken -> IO ()
> sync = takeMVar . syncToken
> awaitSync = takeMVar . syncToken
>
> readMessageChan :: OutChan (Message o) -> IO o
> readMessageChan c = readChan c >>= 
>                      (\(s,i)-> i <$ maybeDo sync s) . message
>
> wrapMessage :: i -> Message i
> wrapMessage = Message . (,) Nothing



    HOW WE USE SyncToken, PASSED WITH EACH MESSAGE:
    -----------------------------------------------

        send:
            - Pass empty MVar, don't check it

        sendSync:
            - Pass empty MVar, block until we can pop ()

        actor receiver:
            - before acting on message, write a () to MVar


> -- | The class of Streams for output with a corresponding 'Mailbox'
> class Stream s where
>
>     -- | Create a new pair of input and output chans: a 'Mailbox' where
>     -- messages can be sent, and an output stream type (currently either an 
>     -- 'IOStream' or 'ActorStream')
>     newChanPair :: (MonadAction m)=> m (Mailbox a, s a)
>
> instance Stream ActorStream where
>     newChanPair = liftIOtoA $ do
>         (inC,outC) <- newSplitChan
>         fLock <- FL <$> newEmptyMVar
>         sLock <- SL <$> newEmptyMVar
>         sMutex <- SLM <$> newMVar sLock
>         return (Mailbox inC (Just sMutex), ActorStream outC sLock fLock)
>

for now, when we make an IOStream / Mailbox pair, the internal Chan is made
available immediately to senders, so senders don't block waiting for a reader in
IO, as they do with an ActorStream (see below):

> instance Stream IOStream where
>     newChanPair = liftIOtoA $ do
>         (inC,outC) <- newSplitChan
>         return (Mailbox inC Nothing, IOStream outC)
>


A channel of communication should never have senders without a receiver. To
enforce this idea, we make 'send' operations block until an Actor is consuming
the corresponding stream. When the runtime determines that a sender will be
blocked indefinitely, an exception will be raised: BlockedIndefinitelyOnMVar. 

This doesn't guarentee that all messages in the Chan will be processed, but in
such a situation, hopefully a BlockedIndefinitelyOnMVar will be raised, which we
can catch and (maybe) use to help garbage collection on the underlying Chan and
in general keep things nice.

In a way, we are always synchronous IN THE MEDIUM and may be synchronous 
IN THE MESSAGE as well by choosing the appropriate 'send' function. 



> -- | Send a message to an Actor asynchronously. This does not wait for the
> -- Actor to receive the message before returning. 
> -- . 
> -- However if we are sending to a Mailbox with a corresponding ActorStream, 
> -- this will block while no Actor is processing the stream. 
> -- . 
> -- If the runtime determines that a new Actor will never take over, an
> -- exception will be raised.
> send :: (MonadAction m)=> Mailbox a -> a -> m ()
> send b = liftIOtoA . putMessage b . wrapMessage
>
>
> -- | Like 'send' but this blocks until the message is received in the
> -- corresponding output stream, e.g. by an 'Actor'. Return 'True' if the
> -- message was processed or 'False' otherwise, e.g. the receiving Actor 
> -- exits prematurely.
> sendSync :: (MonadAction m)=> Mailbox a -> a -> m Bool
> sendSync b a = liftIOtoA $ send' `catches` [Handler blockedHandler]
>     where send' = do                                           
>               st <- ST <$> newEmptyMVar
>               let m = Message (Just st, a)
>               -- block until actor is processing stream and it's our turn
>               putMessage b m
>                -- block until actor reads message
>               awaitSync st        
>               return True
>
>           -- this exception might be raised in `takeMVar sv`. It should not be
>           -- raised in the sendLockDo line.
>           blockedHandler :: SomeException -> IO Bool
>           blockedHandler e = do
>               when dEBUGGING $ putStrLn $ "sendSync: " ++ show e
>               return False
>           
>
> putMessage :: Mailbox a -> Message a -> IO ()
> putMessage b m = 
>     let doPut = writeChan (inChan b) m
>      in case senderLockMutex b of
>              Nothing -> doPut
>               -- TODO: HANDLE THE EXCEPTION THAT WILL BE RE-RAISED HERE.
>               -- BlockedIndefinitelyOnMVar will be raised in waitSenderLock if this chan is
>               -- dead because no actors will ever work on it.
>              (Just slm) ->  
>                    bracket                           
>                      (takeSenderLock slm)            
>                      (putSenderLock slm)             
>                      (\sl-> waitSenderLock sl >> doPut) 


We allow sending of messages to Actors in IO, treating the main thread as 
an Actor with the special privilege to read arbitrarily from an IOStream.

> -- | Read a message from an 'IOStream' in the IO monad. This can be used to
> -- get output from an Actor system. This blocks until there is something to
> -- return
> receive :: IOStream o -> IO o
> receive s = readChan (ioStream s) >>= recv

> -- | Return a lazy list of 'IOStream' contents
> receiveList :: IOStream o -> IO [o]
> receiveList s = getChanContents (ioStream s) >>= mapM recv

> --HELPER:
> recv :: Message b -> IO b
> recv (Message(st,o)) = maybeDo sync st >> return o


The MonadAction class represents environments in which we can operate on actors. 
That is we would like to be able to send a message in IO and Action. 

We could use MonadIO here instead but we want to limit this... maybe that is 
a mistake... We only really care about what can happen in Actor; those functions
have explicit type signatures. For functions that are allowed to happen in IO,
well they should also be able to happen in MonadIO, right?

> -- | monads in the MonadAction class can participate in message passing and other
> -- Actor operations. 
> class Monad m => MonadAction m where
>     liftIOtoA :: IO a -> m a
>
> instance MonadAction IO where
>     liftIOtoA = id
>
> instance MonadAction Action where
>     liftIOtoA = Action . liftIO


Internal function that feeds the actor computation its values.

> actorRunner :: OutChan (Message i) -> Actor i -> IO ()
> actorRunner c = loop
>     where loop a = readMessageChan c >>= 
>                     runAction . stepActor a >>= 
>                      maybeDo loop 


..a simple exported runnner that does not fork, and works in IO:

> -- | run an Actor computation in the main thread, returning when the Actor
> -- exits. Exceptions are not caught:
> runActorUsing :: ActorStream i -> Actor i -> IO ()
> runActorUsing str a =  
>       bracket_
>          -- TODO: CATCH SOME EXCEPTIONS HERE!:
>         (openStream str)
>         (closeStream str)
>         (actorRunner (outChan str) a)


..and a variation where no Chan is involved:

> -- | run an Actor_ actor in the main thread, returning when the computation exits
> runActor_ :: Actor_ -> IO ()
> runActor_ l = runAction (stepActor l ()) >>= 
>                maybeDo runActor_ 



Currently we catch `BlockedIndefinitelyOnMVar` and Actor exits. In such
situations the runtime has determined that a `send` is blocked forever. 

This can propogate: if an Actor exited due to this caught exception it will 
exit. Then either an actor that has been blocked on that ActorStream will take 
over, or senders to the dead ActorStream will raise a BlockedIndefinitelyOnMVar
and exit themselves.


> catchActor :: IO () -> IO ()
> catchActor io = try io >>= either blockedOnMvarHandler return
>     -- raised when runtime finds Actor blocked forever on `send`:
>     where blockedOnMvarHandler :: BlockedIndefinitelyOnMVar -> IO ()
>           blockedOnMvarHandler be = when dEBUGGING $
>                                      putStrLn $ "catchActor: " ++ show be


Finally, the functions for forking Actors:

> -- | fork an actor, returning its input 'Mailbox'
> forkActor :: (MonadAction m)=> Actor i -> m (Mailbox i)
> forkActor a = do
>     (b,str) <- newChanPair
>     forkActorUsing str a
>     return b


FORKING PROCEDURE:
    block waiting to take forkLock
    forkIO:                       
        unblock senders
        run computation
        on exit: 
            block senders
            giveUpStream to other forkers


> -- | fork an actor that reads from the supplied 'ActorStream'. This blocks,
> -- if another Actor is reading from the stream, until that Actor exits.
> forkActorUsing :: (MonadAction m)=> ActorStream i -> Actor i -> m ()
> forkActorUsing str ac = liftIOtoA $ void $ do
>     -- blocks, waiting for other actors to give up control:
>     acquireStream str
>     {-
>     --- TESTING -----------------------------------
>     assertMA $
>         and <$> sequence [ isEmptyMVar lM
>                          , isEmptyMVar lS ]
>     --- TESTING -----------------------------------
>     -}
>     -- Fork actor computation, waiting for first input:
>       -- TODO: HANDLE THE EXCEPTION THAT WILL BE RE-RAISED HERE:
>     forkIO $ bracket_ 
>                  (unblockSenders str) 
>                  (closeStream str)
>                  (actorRunner (outChan str) ac)



> -- | fork a looping computation which starts immediately. Equivalent to
> -- launching an 'Actor_' and another 'Actor' that sends an infinite stream of
> -- ()s
> forkActor_ :: (MonadAction m)=> Actor_ -> m ()
> forkActor_ = liftIOtoA . void . forkIO . runActor_  



> instance Cofunctor Mailbox where
>     cofmap f (Mailbox c l) = Mailbox (cofmap (fmap f) c) l
> 
> instance Cofunctor Actor where
>     cofmap f a = Actor (fmap (cofmap f) . stepActor a . f)
> 
> {- 
> instance Functor IOStream where
>     fmap f (IOStream c) = IOStream (fmap f c)
> -}
>
> instance Functor ActorStream where
>     fmap f (ActorStream c sl fl) = ActorStream (fmap (fmap f) c) sl fl

> -- HELPER:
> maybeDo :: (Monad m) => (a -> m ()) -> Maybe a -> m ()
> maybeDo = maybe (return ())


TESTING
=======

> -- When dEBUGGING is False at compile time and optimizations are turned on, 
> -- this should completely disappear
> assertMA :: (MonadAction m)=> m Bool -> m ()
> assertMA a = when dEBUGGING $ 
>     a >>= liftIOtoA . flip assert (return ())
