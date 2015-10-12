# twittersream.nim

(WIP) A twitter streaming API wrapper library for nim.

## Installation

from github:

```
$ git clone git://github.com/kubo39/twitterstream.nim
$ cd twittersteam.nim && nimble install
```

## Example

```nimrod
import json
import twitterstream

const streamingUrl = "https://userstream.twitter.com/1.1/user.json"

when isMainModule:
  var parsed = parseFile("credential.json")
  var consumerToken = newConsumerToken(parsed["ConsumerKey"].str,
                                       parsed["ConsumerSecret"].str)
  var twitterAPI = newTwitterAPI(consumerToken,
                                 parsed["AccessToken"].str,
                                 parsed["AccessTokenSecret"].str)

  var userStream = twitterAPI.stream("GET", streamingUrl)
  for line in userStream():
    echo line
```
