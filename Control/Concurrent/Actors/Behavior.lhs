> {-# LANGUAGE GeneralizedNewtypeDeriving #-}
> module Control.Concurrent.Actors.Behavior
>     where
> 

Our main data types for actors and behaviors are defined in this private module.
We may expose this if it is useful to people:

These imports are mostly for all the instances for Action that we define:

> -- using 'mtl':
> import Control.Monad.Reader(ReaderT(..))
> import Control.Monad.Reader.Class
> import Control.Monad.Trans.Maybe
> import Control.Monad.IO.Class
> import Control.Applicative
> import Control.Monad
> import Control.Monad.Trans.Class
>
> import Control.Arrow
> import qualified Control.Category as C
>
> import Data.Functor.Contravariant


A Behavior wraps an Action i a, into a list-like sequence of actions to perform
over inputs:

> -- | An 'Action' that returns the @Action@s to be performed on the /next/
> -- input is a @Behavior@.
> newtype Behavior i = Behavior { headAction :: Action i (Behavior i) }
> 
> instance Contravariant Behavior where
>     contramap f (Behavior a) = Behavior $ f ^>> (contramap f <$> a)
>     --contramap f = Behavior . withReaderT f . fmap (contramap f) . headAction
> 
> -- This can probably be a monoid but it's a bit hokey
> --instance Monoid ..
> 


Defining Action as a Reader / Maybe stack lets us have a nice EDSL syntax for
constructing behaviors, and I am able to derive a bunch of the instances that
will be useful:


> -- | In the Actor Model, at each step an actor...
> --
> --     - 'receive's an input to process
> --     
> --     - may spawn new 'Actor's
> --     
> --     - may 'send' messages to other Actors
> --     
> --     - 'return's the 'Behavior' to be performed on the /next/ input
> --
> -- These actions take place within the @Action i@ monad, where @i@ is the type
> -- of the input.
> --
> -- /N.B.:/ the MonadIO instance here is an abstraction leak. An example of a
> -- good use of 'liftIO' might be to give an Action access to a source of
> -- randomness.
> newtype Action i a = Action { readerT :: ReaderT i (MaybeT IO) a }
>         deriving (Monad, MonadIO, MonadPlus, MonadReader i,
>                   Functor, Applicative, Alternative)
> 

Some helpers for wrapping / unwrapping:

> -- pack and unpack:
> runAction :: Action r a -> r -> MaybeT IO a
> runAction = runReaderT . readerT
> 
> action :: (i -> MaybeT IO a) -> Action i a
> action = Action . ReaderT
> 
> runBehaviorStep :: Behavior i -> i -> IO (Maybe (Behavior i))
> runBehaviorStep = fmap runMaybeT . runAction . headAction


Kleisli is ReaderT, so these are basically cribbed from its instances. 

> instance C.Category Action where
>     id = ask
>     f . g = action $ \i-> runAction g i >>= runAction f
> 
> instance Arrow Action where
>     arr = action . fmap return
>     first f = action $ \ ~(b,d)-> runAction f b >>= \c -> return (c,d)
>  
> -- additional Arrow sub-classes:
> instance ArrowApply Action where
>     app = action (uncurry runAction)
> 
> instance ArrowChoice Action where
>     left f = f +++ C.id
> 
> -- and following that MaybeT IO is a MonadPlus...
> instance ArrowPlus Action where
>     f <+> g = action $ \i-> runAction f i `mplus` runAction g i
> 
> instance ArrowZero Action where
>     zeroArrow = action $ const mzero
> 
> 
