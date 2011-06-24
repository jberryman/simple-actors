> module Data.Cofunctor
>     where


This doesn't seem to be a popular class, unfortunately but it's useful for us
here: it lets us transform a Mailbox/sink/processor of one input type to another

> class Cofunctor f where
>     cofmap :: (b -> a) -> f a -> f b
