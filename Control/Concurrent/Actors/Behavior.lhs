> {-# LANGUAGE CPP, GeneralizedNewtypeDeriving #-}
> -- Since we don't get a MonadFix instance for MaybeT from transformers:
> {-# OPTIONS_GHC -fno-warn-orphans #-}
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

> -- | An 'Action' that returns the @Action@s to be performed on the /next/
> -- input is a @Behavior@. Actors are created by 'spawn'ing a @Behavior@. 
> newtype Behavior i = Behavior { headAction :: Action i (Behavior i) }
> 
> instance Contravariant Behavior where
>     contramap f (Behavior a) = Behavior $ f ^>> (contramap f <$> a)
>     --contramap f = Behavior . withReaderT f . fmap (contramap f) . headAction
>

This is essentially a marriage of the Monoid [] instance with Action's
Alternative instance, and I am mostly convinced it is right and has utility:

> -- | @b1 `mplus` b2@ has the 'headAction' of @b2@ begin where the 'abort'
> -- occured in @b1@, i.e. @b2@\'s first input will be the final input handed to
> -- @b1@.
> instance Monoid (Behavior i) where
>     mempty = Behavior mzero
>     mappend (Behavior a1) b2@(Behavior a2) = Behavior $ 
>         -- is this the best way of defining this?:
>         (flip mappend b2 <$> a1) <|> a2


Defining Action as a Reader / Maybe stack lets us have a nice EDSL syntax for
constructing behaviors, and I am able to derive a bunch of the instances that
will be useful:


> -- | In the Actor Model, at each step an actor...
> --
> --     - processes a single 'received' message
> --     
> --     - may spawn new actors
> --     
> --     - may 'send' messages to other actors
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
>                   Functor, Applicative, Alternative, MonadFix)
> 


------ CPP MACROS ------

This should end up in the next version of 'transformers':
   http://www.haskell.org/pipermail/libraries/2011-April/016201.html

#if !MIN_VERSION_transformers(0,3,0)
> instance (MonadFix m) => MonadFix (MaybeT m) where
>    mfix f = MaybeT $ mfix (runMaybeT . f . unJust)
>      where unJust = maybe (error "mfix MaybeT: Nothing") id
#endif

------------------------


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
> -- inspired by MonadFix instance. I'm not sure if this actually works, but
> -- it's copied from the Kleisli definition
> instance ArrowLoop Action where
>    loop af = action (liftM fst . mfix . f')
>        where f' x y = f (x, snd y)
>              f = runAction af
