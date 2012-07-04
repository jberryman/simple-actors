# What's this all about?

`simple-actors` is a haskell eDSL for writing highly-structured concurrent
programs based on the so-called 
[Actor Model](http://en.wikipedia.org/wiki/Actor_model). It provides a far
more structured way of organizing concurrent code than ad-hoc use of `Chan`,
`forkIO` and `MVar`s.

The library was designed to make easy to implement message-passing algorithms
and the like, but as I work on it and learn more about distributed computing,
I'm hoping it can be used across the network eventually.

# How do I do it?

Install with a 

    cabal install simple-actors

and check out the docs [here](http://hackage.haskell.org/package/simple-actors).
