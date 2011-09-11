> module Control.Concurrent.Actors.Chans where
>
> import Control.Concurrent.MVar
> import Control.Concurrent.Chan.Split
> import Control.Concurrent.Chan.Class
> import Data.Cofunctor
> import Control.Monad.IO.Class
> import Control.Concurrent(forkIO)
> import Control.Applicative
> import Control.Exception
> import Control.Monad



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
> -- 'Behaviors' (see 'starting'). This separation of actor initialization and
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
this doesn't actually do a forkIO, which we treat as an unimportant implementation
detail.

> -- | Create a new concurrent 'Actor', returning its 'Mailbox'. Using 'starting' to
> -- initialize a 'Behavior' for the @Actor@ will cause it to unlock its
> -- 'Mailbox' and begin accepting and processing inputs.
> spawnIdle :: (MonadIO m)=> m (Mailbox a, Actor a)
> spawnIdle = liftIO $ do
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



TESTING AND HELPERS:
=====================

It would be nice to put this in a CPP conditional block. Does cabal define a CPP
variable when tests are run?

> dEBUGGING :: Bool
> dEBUGGING = True


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
