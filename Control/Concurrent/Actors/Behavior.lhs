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
> import Control.Monad.Fix
> import Control.Applicative
> import Control.Monad
>
> import Control.Arrow
> import qualified Control.Category as C
> import Data.Monoid
>
> import Data.Functor.Contravariant


A Behavior wraps an Action i a, into a list-like sequence of actions to perform
over inputs:

> newtype Behavior i = Receive { headAction :: Action i (Behavior i) }
> 
> instance Contravariant Behavior where
>     contramap f (Receive a) = Receive $ f ^>> (contramap f <$> a)
>     --contramap f = Receive . withReaderT f . fmap (contramap f) . headAction
>

This is essentially a marriage of the Monoid [] instance with Action's
Alternative instance, and I am mostly convinced it is right and has utility:

> -- | @b1 `mplus` b2@ has the 'headAction' of @b2@ begin where the 'yield'
> -- occured in @b1@, i.e. @b2@\'s first input will be the final input handed to
> -- @b1@.
> instance Monoid (Behavior i) where
>     mempty = Receive mzero
>     mappend (Receive a1) b2@(Receive a2) = Receive $ 
>         -- is this the best way of defining this?:
>         (flip mappend b2 <$> a1) <|> a2


Defining Action as a Reader / Maybe stack lets us have a nice EDSL syntax for
constructing behaviors, and I am able to derive a bunch of the instances that
will be useful:


> newtype Action i a = Action { readerT :: ReaderT i (MaybeT IO) a }
>         deriving (Monad, MonadIO, MonadPlus, MonadReader i,
>                   Functor, Applicative, Alternative, MonadFix)
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


Kleisli is ReaderT, so these are basically cribbed from its instances. It's a
shame ReaderT's type arguments are the way they are or we could have derived
this:

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
> -- inspired by MonadFix instance. 
> instance ArrowLoop Action where
>    loop af = action (liftM fst . mfix . f')
>        where f' x y = f (x, snd y)
>              f = runAction af
