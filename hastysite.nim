import
  json,
  strutils,
  os,
  sequtils,
  tables,
  critbits,
  streams,
  parsecfg,
  logging,
  pegs

{.passL: "-Lpackages/hastyscribe/vendor".}

import
    packages/min/min,
    packages/min/packages/sha1/sha1,
    packages/hastyscribe/hastyscribe,
    packages/moustachu/src/moustachu

import
  config

type
  HastyDirs = object
    assets*: string
    contents*: string
    templates*: string
    output*: string
    temp*: string
    tempContents: string
    scripts*: string
  HastyFiles = object
    rules*: string
    checksums: string
    contents: seq[JsonNode]
    assets: seq[JsonNode]
  HastySite* = object
    settings*: JsonNode
    metadata*: JsonNode
    checksums*: JsonNode
    scripts*: JsonNode
    dirs*: HastyDirs
    files*: HastyFiles 
  NoMetadataException* = ref Exception
  DictionaryRequiredException* = ref Exception
  MetadataRequiredException* = ref Exception

const SCRIPT_BUILD = "./scripts/build.min".slurp
const SCRIPT_CLEAN = "./scripts/clean.min".slurp

let PEG_CSS_VAR_DEF = peg"""'--' {[a-zA-Z0-9_-]+} ':' {@} ';'"""
let PEG_CSS_VAR_INSTANCE = peg"""
  instance <- 'var(--' {id} ')'
  id <- [a-zA-Z0-9_-]+
  """

var CSS_VARS = initTable[string, string]()

#### Helper Functions

proc processCssVariables(text: string): string =
  result = text
  for def in result.findAll(PEG_CSS_VAR_DEF):
    var matches: array[0..1, string]
    discard def.match(PEG_CSS_VAR_DEF, matches)
    let id = matches[0].strip
    let value = matches[1].strip
    CSS_VARS[id] = value
  for instance in result.findAll(PEG_CSS_VAR_INSTANCE):
    var matches: array[0..1, string]
    discard instance.match(PEG_CSS_VAR_INSTANCE, matches)
    let id = matches[0].strip
    if CSS_VARS.hasKey(id):
      result = result.replace(instance, CSS_VARS[id])
    else:
      stderr.writeLine("CSS variable '$1' is not defined." % ["--" & id])

proc preprocessContent(file, dir: string, obj: var JsonNode): string =
  let fileid = file.replace(dir, "")
  var f: File
  discard f.open(file)
  var s, cfg = ""
  result = ""
  var delimiter = 0
  try:
    while f.readLine(s):
      if delimiter  >= 2:
        result &= s&"\n"
      else:
        if s.startsWith("----"):
          delimiter.inc
        else:
          cfg &= s&"\n"
  except:
    discard
  if not obj.hasKey("contents"):
    obj["contents"] = newJObject()
  var meta = newJObject();
  if delimiter < 2:
    result = cfg
  else:
    try:
      let ss = newStringStream(cfg)
      var p: CfgParser
      p.open(ss, file)
      while true:
        var e = next(p)
        case e.kind
        of cfgEof:
          break
        of cfgKeyValuePair:
          meta[e.key] = newJString(e.value)
        of cfgError:
          warn e.msg
        else:
          discard
      p.close()
    except:
      meta = newJObject()
  meta["path"] = %fileid
  meta["id"] = %fileid.changeFileExt("")
  meta["ext"] = %fileid.splitFile.ext
  obj["contents"][fileid] = meta
  f.close()

proc get(json: JsonNode, key, default: string): string =
  if json.hasKey(key):
    return json[key].getStr
  else:
    return default

proc contentMetadata(f, dir: string, meta: JsonNode): JsonNode = 
  result = newJObject()
  let fdata = f.splitFile
  let path = f.replace(dir & DirSep, "")
  if meta.hasKey("contents") and meta["contents"].hasKey(path):
    for key, value in meta["contents"][path].pairs:
      result[key] = value
  result["path"] = %path                    # source path relative to input
  result["type"] = %"content"             
  result["ext"] = %fdata.ext                # output extension
  if fdata.ext == "":
    result["id"] = %path
  else:
    result["id"] = %path.changeFileExt("")  # output path relative to output without extension

proc assetMetadata(f, dir: string): JsonNode = 
  result = newJObject()
  let fdata = f.splitFile
  let path = f.replace(dir & DirSep, "")
  result["path"] = %path                    # source path relative to input
  result["type"] = %"asset"               
  result["ext"] = %fdata.ext                # output extension
  if fdata.ext == "":
    result["id"] = %path
  else:
    result["id"] = %path.changeFileExt("")  # output path relative to output without extension

proc hastysite_module*(i: In, hs1: HastySite)

proc interpret(hs: HastySite, file: string) =
  var i = newMinInterpreter(file, file.parentDir)
  i.hastysite_module(hs)
  i.interpret(newFileStream(file, fmRead))

#### Main Functions

proc newHastySite*(file: string): HastySite = 
  let json = file.parseFile()
  result.settings = json
  result.dirs.assets = json.get("assets", "assets")
  result.dirs.contents = json.get("contents", "contents")
  result.dirs.templates = json.get("templates", "templates")
  result.dirs.output = json.get("output", "output")
  result.dirs.temp = json.get("temp", "temp")
  result.dirs.tempContents = result.dirs.temp / result.dirs.contents
  result.dirs.scripts = json.get("scripts", "scripts")
  result.files.rules = json.get("rules", "rules.min")
  result.files.checksums = result.dirs.temp / "checksums.json"
  result.scripts = newJObject()
  for f in result.dirs.scripts.walkDir(true):
    let path = result.dirs.scripts/f.path
    let file = path.open()
    let desc = file.readLine.replace(";", "")
    let key = f.path.replace(".min", "")
    file.close()
    result.scripts[key] = %desc

proc preprocess*(hs: var HastySite) = 
  if hs.dirs.tempContents.existsDir:
    hs.dirs.tempContents.removeDir
  var meta = newJObject()
  for f in hs.dirs.contents.walkDirRec():
    if f.isHidden:
      continue
    let content = f.preprocessContent(hs.dirs.contents & DirSep, meta)
    let dest = hs.dirs.temp/f
    dest.parentDir.createDir
    dest.writeFile(content)
  if not hs.files.checksums.fileExists:
    let checksums = newJObject()
    hs.files.checksums.writeFile(checksums.pretty)
  hs.checksums = hs.files.checksums.parseFile
  let contents = toSeq(hs.dirs.tempContents.walkDirRec())
  let assets = toSeq(hs.dirs.assets.walkDirRec())
  let contentDir = hs.dirs.tempContents
  let assetDir = hs.dirs.assets
  hs.files.contents = contents.map(proc (f: string): JsonNode = return contentMetadata(f, contentDir, meta))
  hs.files.assets = assets.map(proc (f: string): JsonNode = return assetMetadata(f, assetDir))

proc init*(dir: string) =
  var json = newJObject()
  json["contents"]  = %"contents"
  json["assets"]    = %"assets"
  json["templates"]   = %"templates"
  json["temp"]      = %"temp"
  json["output"]    = %"output"
  json["scripts"]   = %"scripts"
  for key, value in json.pairs:
    createDir(dir/value.getStr)
  json["title"]     = %"My Web Site"
  json["rules"]     = %"rules.min"
  writeFile(dir/json["rules"].getStr, "")
  writeFile(dir/"settings.json", json.pretty)
  writeFile(dir/"scripts/build.min", SCRIPT_BUILD)
  writeFile(dir/"scripts/clean.min", SCRIPT_CLEAN)

proc wasModified(hs: HastySite, sha1: string, outfile: string): bool =
  return (not hs.checksums.hasKey(outfile) or hs.checksums[outfile] != %sha1)

proc updateSHA1(hs: HastySite, sha1: string, outfile: string) =
  hs.checksums[outfile] = %sha1

proc postprocess(hs: HastySite) =
  hs.files.checksums.writeFile(hs.checksums.pretty)

#### min Library

proc hastysite_module*(i: In, hs1: HastySite) =
  var hs = hs1
  let def = i.define()
  
  def.symbol("preprocess") do (i: In):
    hs.preprocess()

  def.symbol("postprocess") do (i: In):
    hs.postprocess()

  def.symbol("process-rules") do (i: In):
    hs.interpret(hs.files.rules)

  def.symbol("clean-output") do (i: In): 
    hs.dirs.output.removeDir

  def.symbol("clean-temp") do (i: In): 
    hs.dirs.temp.removeDir

  def.symbol("metadata") do (i: In):
    i.push i.fromJson(hs.metadata)

  def.symbol("settings") do (i: In):
    i.push i.fromJson(hs.settings)

  def.symbol("contents") do (i: In):
    var contents = newSeq[MinValue](0)
    for j in hs.files.contents:
      contents.add i.fromJson(j)
    i.push contents.newVal(i.scope)

  def.symbol("assets") do (i: In):
    var assets = newSeq[MinValue](0)
    for j in hs.files.assets:
      assets.add i.fromJson(j)
    i.push assets.newVal(i.scope)

  def.symbol("output") do (i: In):
    i.push hs.dirs.output.newVal

  def.symbol("input-fread") do (i: In):
    var vals = i.expect(["dict"])
    var d = vals[0]
    let t = d.dget("type".newVal).getString 
    let path = d.dget("path".newVal).getString
    var contents = ""
    if t == "content":
      contents = readFile(hs.dirs.tempContents/path)
    else:
      contents = readFile(hs.dirs.assets/path)
    i.push contents.newVal

  def.symbol("output-fwrite") do (i: In):
    var vals = i.expect(["dict"])
    var d = vals[0]
    let id = d.dget("id".newVal).getString
    let ext = d.dget("ext".newVal).getString
    var contents = ""
    try:
      contents = d.dget("contents".newVal).getString
    except:
      raise MetadataRequiredException(msg: "Metadata key 'contents' not found in dictionary.")
    let outname = id&ext
    let outfile = hs.dirs.output/outname
    outfile.parentDir.createDir
    let sha1 = compute(contents).toHex
    if hs.wasModified(sha1, outname):
      notice " - Writing file: ", outfile
      hs.updateSHA1(sha1, outname)
      writeFile(outfile, contents)

  def.symbol("output-cp") do (i: In):
    var vals = i.expect(["dict"])
    var d = vals[0]
    let t = d.dget("type".newVal).getString 
    let path = d.dget("path".newVal).getString
    let id = d.dget("id".newVal).getString
    let ext = d.dget("ext".newVal).getString
    var infile, outfile: string
    let outname = id&ext
    if t == "content":
      infile = hs.dirs.tempContents/path
      outfile = hs.dirs.output/outname
    else:
      infile = hs.dirs.assets/path
      outfile = hs.dirs.output/outname
    let sha1 = compute(infile.readFile).toHex
    if hs.wasModified(sha1, outname):
      hs.updateSHA1(sha1, outname)
      notice " - Copying: ", infile, " -> ", outfile
      outfile.parentDir.createDir
      copyFileWithPermissions(infile, outfile)

  def.symbol("preprocess-css") do (i: In):
    var vals = i.expect("string")
    let css = vals[0]
    let res = css.getString.processCssVariables()
    i.push res.newVal()

  def.symbol("mustache") do (i: In):
    var vals = i.expect(["dict", "string"])
    let c = vals[0]
    let t = vals[1]
    let ctx = newContext(%c)
    let tplname = t.getString & ".mustache"
    let tpl = readFile(hs.dirs.templates/tplname)
    i.push tpl.render(ctx, hs.dirs.templates).newval

  def.symbol("markdown") do (i: In):
    var vals = i.expect(["dict", "string"])
    let c = vals[0]
    let t = vals[1]
    let options = HastyOptions(toc: false, output: nil, css: nil, watermark: nil, fragment: true)
    var fields = initTable[string, proc():string]()
    for item in c.qVal:
      closureScope:
        let key = item.qVal[0].getString
        let val = $$item.qVal[1]
        fields[key] = proc(): string = 
          return val
    var hastyscribe = newHastyScribe(options, fields)
    let file = t.getString()
    i.push hastyscribe.compileFragment(file, hs.dirs.contents).newVal

  def.finalize("hastysite")
      
when isMainModule:

  import
    parseopt2

  setLogFilter(lvlNotice)

  proc usage(scripts: bool, hs: HastySite): string = 
    var text = """  $1 v$2 - a tiny static site generator
  (c) 2016-2017 Fabio Cevasco
  
  Usage:
    hastysite command

  Commands:
    init - Initializes a new site in the current directory.
"""
    if scripts:
      for key, value in hs.scripts.pairs:
        text &= "    " & key & " - " & value.getStr & "\n"
    text &= """  Options:
    -h, --help        Print this help
    -l, --loglevel    Sets the log level (one of: debug, info, notice,
                      warn, error, fatal). Default: notice
    -v, --version     Print the program version""" % [appname, version]
    return text

  let pwd = getCurrentDir()
  let cfg = pwd/"settings.json"
  var hs: HastySite
  var scripts = false

  if cfg.fileExists:
    hs = newHastySite(cfg)
    scripts = true

  for kind, key, val in getopt():
    case kind:
      of cmdArgument:
        case key:
          of "init":
            pwd.init()
          else:
            if scripts:
              if hs.scripts.hasKey(key):
                hs.interpret(hs.dirs.scripts/key & ".min")
              else:
                fatal "Script '$1' not found" % key
            else:
              fatal "This directory does not contain a valid HastySite site"
      of cmdLongOption, cmdShortOption:
        case key:
          of "loglevel", "l":
            var v = val
            setLogLevel(v)
          of "help", "h":
            echo usage(scripts, hs)
            quit(0)
          of "version", "v":
            echo version
            quit(0)
          else:
            discard
      else:
        discard
