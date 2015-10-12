import os
import algorithm
import base64
import strtabs
import times
import strutils
import sequtils
import uri
import net
import parseutils

import nuuid
import sha1


const userAgent = "twitterstream.nim/0.1.0"


type
  ProtocolError* = object of IOError   ## exception that is raised when server
                                       ## does not conform to the implemented
                                       ## protocol

  HttpRequestError* = object of IOError ## Thrown in the ``getContent`` proc
                                        ## and ``postContent`` proc,
                                        ## when the server returns an error

  ConsumerTokenImpl = object
    consumerKey: string
    consumerSecret: string

  ConsumerToken = ref ConsumerTokenImpl

  TwitterAPIImpl = object
    consumerToken: ConsumerToken
    accessToken: string
    accessTokenSecret: string

  TwitterAPI* = ref TwitterAPIImpl


proc newConsumerToken*(consumerKey, consumerSecret: string): ConsumerToken =
  return ConsumerToken(consumerKey: consumerKey,
                       consumerSecret: consumerSecret)


proc newTwitterAPI*(consumerToken: ConsumerToken, accessToken, accessTokenSecret: string): TwitterAPI =
  return TwitterAPI(consumerToken: consumerToken,
                    accessToken: accessToken,
                    accessTokenSecret: accessTokenSecret)


proc newTwitterAPI*(consumerKey, consumerSecret, accessToken, accessTokenSecret: string): TwitterAPI =
  let consumerToken: ConsumerToken = ConsumerToken(consumerKey: consumerKey,
                                                   consumerSecret: consumerSecret)
  return TwitterAPI(consumerToken: consumerToken,
                    accessToken: accessToken,
                    accessTokenSecret: accessTokenSecret)



proc httpError(msg: string) =
  var e: ref ProtocolError
  new(e)
  e.msg = msg
  raise e


# Utils

# Stolen from cgi.nim
proc encodeUrl(s: string): string =
  # Exclude A..Z a..z 0..9 - . _ ~
  # See https://dev.twitter.com/oauth/overview/percent-encoding-parameters
  result = newStringOfCap(s.len + s.len shr 2) # assume 12% non-alnum-chars
  for i in 0..s.len-1:
    case s[i]
    of 'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '~': add(result, s[i])
    else:
      add(result, '%')
      add(result, toHex(ord(s[i]), 2))


proc padding(k: seq[uint8]): seq[uint8] =
  if k.len > 64:
    var arr = newSeq[uint8](64)
    for i, x in sha1.compute(cast[string](k)):
      arr[i] = x
    return arr
  else:
    return k


proc hmacSha1(key, message: string): SHA1Digest =
  var k1: seq[uint8] = padding(cast[seq[uint8]](key))
  var k2: seq[uint8] = padding(cast[seq[uint8]](key))

  k1.mapIt(it xor 0x5c)
  k2.mapIt(it xor 0x36)

  var arr: seq[uint8] = @[]

  for x in sha1.compute(cast[string](k2) & message):
    arr.add(x)

  return sha1.compute(k1 & arr)


proc signature(consumerSecret, accessTokenSecret, httpMethod, url: string, params: StringTableRef): string =
  var keys: seq[string] = @[]

  for key in params.keys:
    keys.add(key)

  keys.sort(cmpIgnoreCase)

  let query = keys.map(proc(it: string): string = it & "=" & params[it]).join("&")
  let key = encodeUrl(consumerSecret) & "&" & encodeUrl(accessTokenSecret)
  let base = httpMethod & "&" & encodeUrl(url) & "&" & encodeUrl(query)

  return encodeUrl(hmacSha1(key, base).toBase64)


proc buildParams(consumerKey, accessToken: string,
                 additionalParams: StringTableRef = nil): StringTableRef =
  var params: StringTableRef = { "oauth_version": "1.0",
                                 "oauth_consumer_key": consumerKey,
                                 "oauth_nonce": generateUUID(),
                                 "oauth_signature_method": "HMAC-SHA1",
                                 "oauth_timestamp": epochTime().toInt.repr,
                                 "oauth_token": accessToken }.newStringTable

  for key, value in params:
    params[key] = encodeUrl(value)
  if additionalParams != nil:
    for key, value in additionalParams:
      params[key] = encodeUrl(value)
  return params


proc newHeaders(httpMethod, url: string, keys: seq[string], params: StringTableRef = nil): string =
  let authorizeKeys = keys.filter(proc(x: string): bool = x.startsWith("oauth_"))
  let authorize = "OAuth " & authorizeKeys.map(proc(it: string): string = it & "=" & params[it]).join(",")

  var r = parseUri(url)

  var headers = httpMethod
  headers.add ' '
  if r.path[0] != '/': headers.add '/'
  headers.add(r.path)
  if r.query.len > 0:
    headers.add("?" & r.query)
  headers.add(" HTTP/1.1\c\L")
  if r.port == "":
    headers.add("Host: " & r.hostname & "\c\L")
  else:
    headers.add("Host: " & r.hostname & ":" & r.port & "\c\L")
  headers.add("User-Agent: " & userAgent & "\c\L")
  headers.add("Authorization: " & authorize & "\c\L")
  headers.add("\c\L")
  result = headers


proc parseHeader(s: Socket) =
  var parsedStatus = false
  var linei = 0
  var fullyRead = false
  var line = ""
  var timeout = -1
  var headers = newStringTable(modeCaseInsensitive)
  var version = ""
  var status = ""

  while true:
    line = ""
    linei = 0
    s.readLine(line, timeout)
    if line == "": break # We've been disconnected.
    if line == "\c\L":
      fullyRead = true
      break
    if not parsedStatus:
      # Parse HTTP version info and status code.
      var le = skipIgnoreCase(line, "HTTP/", linei)
      if le <= 0: httpError("invalid http version")
      inc(linei, le)
      le = skipIgnoreCase(line, "1.1", linei)
      if le > 0: version = "1.1"
      else:
        le = skipIgnoreCase(line, "1.0", linei)
        if le <= 0: httpError("unsupported http version")
        version = "1.0"
      inc(linei, le)
      # Status code
      linei.inc skipWhitespace(line, linei)
      status = line[linei .. ^1]
      parsedStatus = true
    else:
      # Parse headers
      var name = ""
      var le = parseUntil(line, name, ':', linei)
      if le <= 0: httpError("invalid headers")
      inc(linei, le)
      if line[linei] != ':': httpError("invalid headers")
      inc(linei) # Skip :
      headers[name] = line[linei.. ^1].strip()


proc stream*(client: TwitterAPI, httpMethod, url: string,
             additionalParams: StringTableRef = nil): iterator(): string =
  var keys: seq[string] = @[]
  var params: StringTableRef = buildParams(client.consumerToken.consumerKey,
                                           client.accessToken,
                                           additionalParams)
  params["oauth_signature"] = signature(client.consumerToken.consumerSecret,
                                        client.accessTokenSecret,
                                        httpMethod, url, params)

  for key in params.keys:
    keys.add(key)

  var headers = newHeaders(httpMethod, url, keys, params)
  let path = keys.map(proc(it: string): string = it & "=" & params[it]).join("&")

  var socket = newSocket(buffered = false)
  if socket == nil: raiseOSError(osLastError())
  let sslContext = newContext(verifyMode = CVerifyNone)
  sslContext.wrapSocket(socket)

  let port = net.Port(443)
  var r = parseUri(url)

  return iterator(): string =
    socket.connect(r.hostname, port)
    echo headers
    socket.send(headers)
    parseHeader(socket)

    # parse body
    var line = ""
    while true:
      socket.readLine(line)
      if line != "":
        yield line
        line = ""
    socket.close()
