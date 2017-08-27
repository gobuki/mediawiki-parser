{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Parsing MediaWiki XML dumps.
module Data.MediaWiki.XmlDump
    ( parseWikiDocs
    , WikiDoc(..)
    , Format(..)
    , PageId(..)
    , Namespace(..)
    , NamespaceId(..)
    ) where

import GHC.Generics
import Text.XML.Expat.SAX
import           Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

newtype Namespace = Namespace T.Text
                  deriving (Eq, Ord, Show, Generic)

newtype NamespaceId = NamespaceId Int
                    deriving (Eq, Ord, Enum, Show, Generic)

newtype PageId = PageId Int
               deriving (Eq, Ord, Enum, Show, Generic)

data Format = XWiki
            | OtherFormat ByteString
            deriving (Show, Generic)

data WikiDoc = WikiDoc { docTitle     :: ByteString
                       , docNamespace :: NamespaceId
                       , docPageId    :: PageId
                       , docRedirects :: [ByteString]
                       , docFormat    :: Format
                       , docText      :: ByteString
                       }
             deriving (Show, Generic)

entities :: HM.HashMap ByteString ByteString
entities = HM.fromList
    [ ("gt", ">")
    , ("lt", "<")
    , ("amp", "&")
    , ("quot", "\"")
    ]

parseWikiDocs :: BSL.ByteString -> ([(NamespaceId, Namespace)], [WikiDoc])
parseWikiDocs = parseWikiDocs' . parse parseOpts
  where
    parseOpts = defaultParseOptions { entityDecoder = Just (`HM.lookup` entities) }

parseWikiDocs' :: [SAXEvent ByteString ByteString] -> ([(NamespaceId, Namespace)], [WikiDoc])
parseWikiDocs' xs0 =
    let (prelude, docsElems) = span (not . isEndTag "namespaces") xs0
        namespaces = parseNamespaces prelude
    in (namespaces, parsePages docsElems)
  where
    parseNamespaces :: [SAXEvent ByteString ByteString] -> [(NamespaceId, Namespace)]
    parseNamespaces [] = []
    parseNamespaces xs =
      let (ns, rest) = break (isEndTag "namespace") $ dropWhile (not . isStartTag "namespace") xs
      in case ns of
           (StartElement _ attrs) : _
             | Just key <- NamespaceId . read . BS.unpack <$> lookup "key" attrs ->
               let name = Namespace $ T.decodeUtf8 $ getContent ns
               in (key, name) : parseNamespaces rest
           _ -> parseNamespaces rest

    parsePages :: [SAXEvent ByteString ByteString] -> [WikiDoc]
    parsePages [] = []
    parsePages xs =
      let (page, rest) = break (isEndTag "page") $ dropWhile (not . isStartTag "page") xs
      in parsePage emptyDoc page : parsePages rest

    emptyDoc = WikiDoc { docTitle = ""
                       , docNamespace = NamespaceId 0
                       , docPageId = PageId 0
                       , docRedirects = []
                       , docFormat = OtherFormat ""
                       , docText = ""
                       }

    parsePage :: WikiDoc -> [SAXEvent ByteString ByteString] -> WikiDoc
    parsePage doc [] = doc
    parsePage doc (x:xs)
      | isStartTag "title" x =
          let (content, xs') = break (isEndTag "title") xs
              doc' = doc {docTitle = getContent content}
          in parsePage doc' xs'
      | isStartTag "ns" x =
          let (content, xs') = break (isEndTag "ns") xs
              doc' = doc {docNamespace = toEnum $ read $ BS.unpack $ getContent content}
          in parsePage doc' xs'
      | isStartTag "id" x =
          let (content, xs') = break (isEndTag "id") xs
              doc' = doc {docPageId = toEnum $ read $ BS.unpack $ getContent content}
          in parsePage doc' xs'
      | isStartTag "redirect" x =
          let StartElement _ attrs = x
              Just title = lookup "title" attrs
              doc' = doc {docRedirects = title : docRedirects doc}
          in parsePage doc' xs
      | isStartTag "format" x =
          let (content, xs') = break (isEndTag "format") xs
              doc' = doc {docFormat = parseFormat $ getContent content}
          in parsePage doc' xs'
      | isStartTag "text" x =
          let (content, xs') = break (isEndTag "text") xs
              doc' = doc {docText = getContent content}
          in parsePage doc' xs'
      | isStartTag "page" x = parsePage doc xs
      | otherwise           = parsePage doc xs
      where
        parseFormat "text/x-wiki" = XWiki
        parseFormat other         = OtherFormat other

getContent :: [SAXEvent ByteString ByteString] -> ByteString
getContent =
    BSL.toStrict . foldMap getCharData
  where
    getCharData (CharacterData text) = BSL.fromStrict text
    getCharData _                    = BSL.empty

isStartTag :: Eq tag => tag -> SAXEvent tag text -> Bool
isStartTag tag (StartElement tag' _) = tag == tag'
isStartTag _   _ = False

isEndTag :: Eq tag => tag -> SAXEvent tag text -> Bool
isEndTag tag (EndElement tag') = tag == tag'
isEndTag _   _ = False
