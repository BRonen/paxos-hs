module App
    ( app
    ) where

import Web.Scotty (get, html, pathParam, scotty)
import Options.Generic (getRecord)
import Data.List (find)
import Data.Time.Clock.POSIX (getPOSIXTime)

data Node = Node { nodeId :: Int, port :: Int }
  deriving (Show)

data Proposal = Proposal { proposalId :: Int, proposalValue :: Maybe String }
  deriving (Show)

data Proposer = Proposer { proposerId :: Int }
  deriving (Show)

data Acceptor = Acceptor { lastProposalId :: Int , acceptedProposal :: Maybe Proposal }
  deriving (Show)

getNodes :: Int -> (Maybe Node, [Node])
getNodes selfId = (
  find (\(Node { nodeId = nodeId' }) -> selfId == nodeId') nodes,
  filter (\(Node { nodeId = nodeId' }) -> selfId /= nodeId') nodes
  )
    where
      nodes = [
        Node { nodeId = 0, port = 4000 },
        Node { nodeId = 1, port = 4001 },
        Node { nodeId = 2, port = 4002 }
        ]

getNodeId :: IO Int
getNodeId = getRecord "Paxos-hs" :: IO Int

createProposal :: Maybe String -> IO Proposal
createProposal value = do
  timestamp <- (round . (* 1000)) <$> getPOSIXTime
  pure $ Proposal { proposalId = timestamp, proposalValue = value }

app :: IO ()
app = do
  selfId <- getNodeId
  let (maybeSelfNode, nodes) = getNodes selfId

  print (maybeSelfNode, nodes)

  p <- createProposal $ Just "hello world"

  print p

  case maybeSelfNode of
    Nothing -> pure ()
    Just selfNode -> do
      scotty (port selfNode) $ do
        get "/:word" $ do
          beam <- pathParam "word"
          html $ mconcat ["<h1>Scotty, ", beam, " me up!</h1>"]
        get "/" $ do
          html $ mconcat ["<h1>Hello world!</h1>"]
