//
//  BertTokenizer.swift
//
//  Re-exports the shared BertTokenizer from WaxBertTokenizer so that existing
//  internal references (e.g. MiniLMEmbeddings.swift) continue to compile
//  without changes.
//

@_exported import WaxBertTokenizer
