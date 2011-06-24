> {-# LANGUAGE CPP, GeneralizedNewtypeDeriving, ViewPatterns #-}

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
>     , module Data.Cofunctor --necessary?
>     ) where
>
> import Control.Monad
> import Control.Monad.IO.Class
> import Control.Monad.Trans.Maybe
> import Control.Concurrent
> import Control.Applicative
> 
> import Data.Cofunctor




------

These macros are only provided by cabal unfortunately.... makes it difficult to
work with GHCi:

#if MIN_VERSION_base(4,3,0)
> import Control.Exception(try,mask_,BlockedIndefinitelyOnMVar)
> 
#else
> import Control.Exception(try,block,BlockedIndefinitelyOnMVar)
>
> mask_ :: IO a -> IO a
> mask_ = block
> 
> void :: (Monad m)=> m a -> m ()
> void = (>> return ())
#endif

------

It would  be nice to put this in a CPP conditional block. Does cabal do this
automatically when running built-in tests?

> dEBUGGING = True
>
> -- When dEBUGGING is False at compile time and optimizations are turned on, 
> -- this should completely disappear
> assertIO :: IO Bool -> IO ()
> assertIO io | dEBUGGING = io >>= flip assert (return ())
>             | otherwise = return ()



TODO
-----
    - move Cofunctor to a separate module and import/export
    - make ActorStream a Functor
    - define Mailbox as a GADT and make a cofunctor

    - sendSync should return a Bool indicating success or failure
        - catch BlockedIndefinitelyOnMVar and return False
    - add assertIOs and test, test, test

    - better documentation:
        - show implementation in docs when it reveals something
        - examples
        - explanations when useful

    - test performance of send blocking and not blocking
    - automated tests / assertions (with HUnit?)
    - better exception handling with an eye for helping the GC

    - export some useful Actors:
        - 'loop' which keeps consuming
        - function returning an actor to "load balance" inputs over multiple
          actors





Here we define the Actor environment, similar to IO, in which we can launch new
Actors and send messages to Actors in scope. The implementation is hidden from
the user to enforce these restrictions.

> -- | The Actor encironment in which Actors can be spawned and sent messages
> newtype Action a = Action { action :: MaybeT IO a }
>                  deriving (Monad, Functor, Applicative, 
>                            Alternative, MonadPlus, MonadIO)
>
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
> newtype Mailbox i = Mailbox { mailbox :: LockedChan i }
>
> -- | A stream of messages, received via a corresponding 'Mailbox', which can
> -- /only/ act as input for an 'Actor' computation
> data ActorStream i = ActorStream 
>     -- keep Mailbox wrapper, so we don't mix these up:
>     { lockedMailbox :: Mailbox i
>     , lockedStream :: LockedChan i 
>     }


    NOTE: we don't use a locking mechanism for IOStream for now, but may 
     put some kind of signalling mechanism in later. This would probably 
     have to use STM to be useful and avoid race conditions.


> -- | A stream of messages, received via a corresponding 'Mailbox', which can
> -- be freely read from only in the IO Monad.
> data IOStream i = IOStream { ioStream :: MessageChan i }


We "lock" the Chans behind an MVar to enable two things:
    1) Sends will block until there is an Actor processing the stream
    2) Attempting to fork on an ActorStream will block until no other Actor
        is processing the stream

    NOTE: currently 'send's to a Mailbox with a corresponding IOStream will
          never block. We should use an internal class to allow us to ditch the
          MVar wrapping for sends to IOStream.

> type LockedChan i = MVar (MessageChan i)


    HOW WE USE THE LockedChan PAIRS:
    --------------------------------

        newChanPair:
            - create one newEmptyMVar for both 'lockedMailbox' and 'mailbox'
            - create one newMVar from a newChan, for 'lockedStream'

                         ActorStream
                     --------    =======
                    |  chan  |  |       |
                     --------    =======
                                 Mailbox
        forkActorOn:
            - blocks on 'takeMVar . lockedStream'
            - (assert both MVars are empty)
            - 'putMVar chan . lockedMailbox' (unblocking 'send'ers)
            - (aser lockedStream MVar empty until Actor exits)

        send:
            - blocks on 'takeMVar . mailbox'

        done (or exception handled):
            - (assert lockedStream empty (lockedMailbox may not be empty if the
                exception was immediate))
            - 'takeMVar . lockedMailbox' 
            - 'putMVar chan . lockedStream' (unblocking 'forkActorsOn's)

        

The internal message type. The addition of an MVar allows for syncronous message
passing between Actors:

> type MessageChan i = Chan (Message i)
> newtype Message i = Message { message :: (Maybe SyncToken, i) } 
>                   deriving Functor
> type SyncToken = MVar ()
>
> readMessageChan :: MessageChan i -> IO i
> readMessageChan c = readChan c >>= 
>                      (\(s,i)-> i <$ maybeDo takeMVar s) . message


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
>     -- | Create a new pair of input and output chans: a 'Mailbox' where
>     -- messages can be sent, and an output stream type (currently either an 
>     -- 'IOStream' or 'ActorStream')
>     newChanPair :: (MonadAction m)=> m (Mailbox a, s a)
>
> instance Stream ActorStream where
>     newChanPair = liftIOtoA $ do
>         b <- Mailbox <$> newEmptyMVar
>         str <- newChan >>= newMVar
>         return (b, ActorStream b str)
>
> instance Stream IOStream where
>     newChanPair = liftIOtoA $ do
>         c <- newChan
>         b <- Mailbox <$> newMVar c
>         return (b, IOStream c)
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
> send (mailbox-> b) = liftIOtoA . send' . Message . (,) Nothing
>     where send' m = do
>           c <- readMVar b    -- block until actor processing
>           writeChan c m 
>
> -- | Like 'send' but this blocks until the message is read in the
> -- corresponding stream
> sendSync :: (MonadAction m)=> Mailbox a -> a -> m ()
> sendSync (mailbox-> b) a = liftIOtoA $ do
>     sv <- newEmptyMVar
>     let m = Message (Just sv, a)
>     c <- readMVar b    -- block until actor processing
>     writeChan c m 
>     void $ takeMVar sv -- block until the actor reads message
>     


We allow sending of messages to Actors in IO, treating the main thread as 
an Actor with the special privilege to read arbitrarily from an IOStream.

> -- | Read a message from an 'IOStream' in the IO monad. This can be used to
> -- get output from an Actor system. This blocks until their is something to
> -- return
> receive :: IOStream o -> IO o
> receive = (recv =<<) . readChan . ioStream

> -- | Return a lazy list of 'IOStream' contents
> receiveList :: IOStream o -> IO [o]
> receiveList = (mapM recv =<<) . getChanContents . ioStream

> --HELPER:
> recv (Message(snc,o)) = maybeDo (void . takeMVar) snc >> return o


The MonadAction class represents environments in which we can operate on actors. 
That is we would like to be able to send a message in IO and Action.

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

> actorRunner :: MessageChan i -> Actor i -> IO ()
> actorRunner c = loop
>     where loop a = readMessageChan c >>= 
>                     runAction . stepActor a >>= 
>                      maybeDo loop 


..a simple exported runnner that does not fork, and works in IO:

> -- | run an Actor computation in the main thread, returning when the Actor
> -- exits. No exceptions are caught.
> runActorUsing :: ActorStream i -> Actor i -> IO ()
> runActorUsing astr f = flip actorRunner f =<< unlockStream astr


..and a variation we export, where no Chan is involved:

> -- | run an Actor_ actor in the main thread, returning when the computation exits
> runActor_ :: Actor_ -> IO ()
> runActor_ l = runAction (stepActor l ()) >>= 
>                maybeDo runActor_ 


This function performs the actual forking of a new Actor computation, followed
by the "cleanup" work of replacing the Chan into the 'lockedStream' MVar. The
IO action it forks handles errors.

> -- USE `bracket` HERE?:
> forkA :: ActorStream i -> IO () -> IO ()
> forkA astr = void . forkIO . (>> cleanup) . catchActor  where
>
>     cleanup = mask_ $ do 
>          -- should only ever be blocked briefly:
>         c <- takeMVar $ mailbox $ lockedMailbox astr
>          -- (assert both MVars are now empty) --
>         putMVar (lockedStream astr) c  -- (unblocks forking actors)


No cleanup necessary here, just silence exception:

> forkA_ :: IO () -> IO ()
> forkA_ = void . forkIO . catchActor 


Currently we catch `BlockedIndefinitelyOnMVar` and Actor exits. In such
situations the runtime has determined that a `send` is blocked forever. This can
propogate, in that if an Actor exited due to this caught exception, senders to 
that actor might do the same if no other Actor is forked on the Stream.


> catchActor :: IO () -> IO ()
> catchActor io = try io >>= either blockedOnMvarHandler return
>     -- raised when runtime finds Actor blocked forever on `send`:
>     where blockedOnMvarHandler :: BlockedIndefinitelyOnMVar -> IO ()
>           blockedOnMvarHandler = when dEBUGGING . print


Finally, the functions for forking Actors:

> -- | fork an actor, returning its input 'Mailbox'
> forkActor :: (MonadAction m)=> Actor i -> m (Mailbox i)
> forkActor a = do
>     (b,str) <- newChanPair
>    -- (assert 'str' full, 'b' empty) --
>     forkActorUsing str a
>     return b
>
>
> -- | fork an actor that reads from the supplied 'ActorStream'. This blocks,
> -- if another Actor is reading from the stream, until that Actor exits.
> forkActorUsing :: (MonadAction m)=> ActorStream i -> Actor i -> m ()
> forkActorUsing astr f = liftIOtoA $ do
>     let b = mailbox $ lockedMailbox astr
>     -- block, waiting for other actors to give up control:
>     c <- unlockStream astr
>     -- Fork actor computation, waiting for first input:
>     forkA astr (actorRunner c f) 
>     -- put the chan into the MVar, unblocking senders (or forkA cleanup):
>     putMVar b c
>
>
> -- | fork a looping computation which starts immediately. Equivalent to
> -- launching an 'Actor_' and another 'Actor' that sends an infinite stream of
> -- ()s
> forkActor_ :: (MonadAction m)=> Actor_ -> m ()
> forkActor_ = liftIOtoA . forkA_ . runActor_  
>
>
> -- Blocks until we can take the Chan from the actorStream MVar to run an 
> -- actor on its stream:
> unlockStream :: ActorStream i -> IO (MessageChan i)
> unlockStream = takeMVar . lockedStream
>              -- (Then assert both MVars are empty) --



> --TODO: REDEFINE MAILBOX TO SUPPORT THIS:
> --instance Cofunctor Mailbox where
> --    cofmap = undefined
> 
> instance Cofunctor Actor where
>     cofmap f a = Actor (fmap (cofmap f) . stepActor a . f)
> 


> -- HELPER:
> maybeDo :: (Monad m) => (a -> m ()) -> Maybe a -> m ()
> maybeDo = maybe (return ())


