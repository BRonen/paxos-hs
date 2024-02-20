module App
    ( app
    ) where

import Web.Scotty (get, html, pathParam, scotty)
import Options.Generic (getRecord)

nodes :: [Int]
nodes = [4000, 4001, 4002]

getNodeId :: IO Int
getNodeId = getRecord "Paxos-hs" :: IO Int

app :: IO ()
app = do
  nodeId <- getNodeId
  let port = nodes!!nodeId

  scotty port $ do
    get "/:word" $ do
      beam <- pathParam "word"
      html $ mconcat ["<h1>Scotty, ", beam, " me up!</h1>"]
    get "/" $ do
      html $ mconcat ["<h1>Hello world!</h1>"]
