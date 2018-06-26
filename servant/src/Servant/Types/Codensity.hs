{-# LANGUAGE RankNTypes #-}
module Servant.Types.Codensity (Codensity (..)) where

import           Control.Monad.Codensity
                 (Codensity (..))
{-
#else
import           Control.Monad.IO.Class
                 (MonadIO (..))
import           Control.Monad.Trans.Class
                 (MonadTrans (..))
import           Prelude ()
import           Prelude.Compat

newtype Codensity m a = Codensity
    { runCodensity :: forall b. (a -> m b) -> m b
    }

instance Functor (Codensity k) where
    fmap f (Codensity m) = Codensity (\k -> m (k . f))
    {-# INLINE fmap #-}

instance Applicative (Codensity f) where
    pure x = Codensity (\k -> k x)
    {-# INLINE pure #-}
    Codensity f <*> Codensity g = Codensity (\bfr -> f (\ab -> g (bfr . ab)))
    {-# INLINE (<*>) #-}

instance Monad (Codensity f) where
    return = pure
    {-# INLINE return #-}
    m >>= k = Codensity (\c -> runCodensity m (\a -> runCodensity (k a) c))
    {-# INLINE (>>=) #-}

instance MonadTrans Codensity where
    lift m = Codensity (m >>=)
    {-# INLINE lift #-}

instance MonadIO m => MonadIO (Codensity m) where
    liftIO = lift . liftIO
    {-# INLINE liftIO #-}
#endif
-}
