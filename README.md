# paxos-hs

Usage:

run these commands in multiple sessions of your shell

```sh
$ stack run -- 1 # running at 4000
$ stack run -- 2 # running at 4001
$ stack run -- 3 # running at 4002
$ stack run -- 4 # running at 4003
$ stack run -- 5 # running at 4004
```

each of these processes will have some roles in the paxos algorithm

```hs
Node {
    nodeId = 1,
    addr = "http://0.0.0.0:4000",
    proposer = Just initialProposer, -- is/has a proposer instance
    acceptor = Nothing,
    learner = Nothing
    },
  Node {
    nodeId = 2,
    addr = "http://0.0.0.0:4001",
    proposer = Nothing,
    acceptor = Just initialAcceptor, -- is/has an acceptor instance
    learner = Nothing
    },
  Node {
    nodeId = 3,
    addr = "http://0.0.0.0:4002",
    proposer = Just initialProposer, -- is/has a proposer instance and
    acceptor = Just initialAcceptor, -- an acceptor instance
    learner = Nothing
    },
  Node {
    nodeId = 4,
    addr = "http://0.0.0.0:4003",
    proposer = Just initialProposer,-- is/has a proposer instance and
    acceptor = Just initialAcceptor, -- an acceptor instance
    learner = Nothing
    },
  Node {
    nodeId = 5,
    addr = "http://0.0.0.0:4004",
    proposer = Just initialProposer,-- is/has a proposer instance,
    acceptor = Just initialAcceptor, -- an acceptor instance and
    learner = Just initialLearner -- a learner instance
    }
```

this setup can be changed without any problems on the source code
and each of these roles have their own routes

```c
[post] "/acceptor/prepare" -> acceptor prepare phase {internal only}
[post] "/acceptor/commit" -> acceptor commit phase {internal only}
[get] "/acceptor/debug" -> get the current state of an acceptor
[post] "/learner" -> set the value of a learner {internal only}
[get] "/learner" -> get the current value of a learner
[post] "/proposer" -> create a new proposal
[post] "/" -> healthcheck
```

example of payload to send on `[post] /propose` (send as json)

```json
"value"
```

example of output of `[get] /learner` after propose is processed

```hs
Just (Proposal {proposalId = 1708581498892, proposalValue = Just "hello world"})
```

## References

- [https://lamport.azurewebsites.net/pubs/paxos-simple.pdf](https://lamport.azurewebsites.net/pubs/paxos-simple.pdf)
