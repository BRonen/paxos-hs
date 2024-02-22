module Main (main) where

import Options.Generic (getRecord)
import App (app)

getNodeId :: IO Int
getNodeId = getRecord "Paxos-hs"

main :: IO ()
main = getNodeId >>= app
