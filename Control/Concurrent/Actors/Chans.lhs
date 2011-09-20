> module Control.Concurrent.Actors.Chans where
>
> import Control.Concurrent.MVar
> import Control.Concurrent.Chan.Split
> import Control.Concurrent.Chan.Class
> import Data.Functor.Contravariant
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
> -- Actor reading from the corresponding 'InputStream' where they can be 
> -- processed by a 'Behavior'. 
> newtype Mailbox i = Mailbox { inChan :: InChan i }
>                    
>
> -- | A stream of messages sent to a correspondind 'Mailbox'. An actor can be
> -- spawned taking input from a user
> data InputStream i = InputStream { outChan :: OutChan i }
>
> instance Contravariant Mailbox where
>     contramap f = Mailbox . contramap f
> 
> instance Functor InputStream where
>     fmap f = InputStream . fmap f . outChan


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
