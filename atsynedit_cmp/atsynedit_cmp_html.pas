{
Copyright (C) Alexey Torgashin, uvviewsoft.com
License: MPL 2.0 or LGPL
}
unit ATSynEdit_Cmp_HTML;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  ATStringProc_Separator,
  ATSynEdit,
  ATSynEdit_Cmp_HTML_Provider;

procedure DoEditorCompletionHtml(Ed: TATSynEdit);

type
  TATCompletionOptionsHtml = record
    Provider: TATHtmlProvider;
    ListOfTags: TStringList;
    FilenameHtmlList: string; //from CudaText: data/autocompletespec/html_list.ini
    FilenameHtmlGlobals: string; //from CudaText: data/autocompletespec/html_globals.ini
    FilenameHtmlEntities: string; //from CudaText: data/autocompletespec/html_entities.ini
    FileMaskHREF: string;
    FileMaskLinkHREF: string;
    FileMaskPictures: string;
    FileMaskScript: string;
    FileMaskFrame: string;
    FileMaskAudio: string;
    FileMaskVideo: string;
    FileMaskSomeSrc: string;
    PrefixTag: string;
    PrefixAttrib: string;
    PrefixValue: string;
    PrefixDir: string;
    PrefixFile: string;
    PrefixEntity: string;
    MaxLinesPerTag: integer;
    NonWordChars: UnicodeString;
  end;

var
  CompletionOpsHtml: TATCompletionOptionsHtml;

implementation

uses
  SysUtils, Graphics, StrUtils,
  ATStringProc,
  ATSynEdit_Carets,
  ATSynEdit_RegExpr,
  ATSynEdit_Cmp_Form,
  ATSynEdit_Cmp_CSS,
  ATSynEdit_Cmp_Filenames,
  Dialogs,
  Math;

type
  TCompletionHtmlContext = (
    ctxNone,
    ctxTags,
    ctxAttrs,
    ctxValues,
    ctxValuesQuoted,
    ctxEntity,
    ctxValueHref,
    ctxValueLinkHref,
    ctxValueFrameSrc,
    ctxValueScriptSrc,
    ctxValueImageSrc,
    ctxValueAudioSrc,
    ctxValueVideoSrc,
    ctxValueSourceSrc
    );

function IsQuote(ch: WideChar): boolean; inline;
begin
  case ch of
    '"', '''':
      Result:= true;
    else
      Result:= false;
  end;
end;

function IsQuoteOrSlash(ch: WideChar): boolean; inline;
begin
  case ch of
    '"', '''', '/', '\':
      Result:= true;
    else
      Result:= false;
  end;
end;

procedure EditorGetDistanceToQuotes(Ed: TATSynEdit; out ALeft, ARight: integer; out AAddSlash: boolean);
var
  Caret: TATCaretItem;
  S: UnicodeString;
  Len, X, i: integer;
begin
  ALeft:= 0;
  ARight:= 0;
  AAddSlash:= true;

  Caret:= Ed.Carets[0];
  if not Ed.Strings.IsIndexValid(Caret.PosY) then exit;
  S:= Ed.Strings.Lines[Caret.PosY];
  Len:= Length(S);
  X:= Caret.PosX+1;

  i:= X;
  while (i<=Len) and not IsQuote(S[i]) do Inc(i);
  ARight:= i-X;

  i:= X;
  while (i>1) and (i<=Len) and not IsQuoteOrSlash(S[i-1]) do Dec(i);
  ALeft:= Max(0, X-i);
end;


function IsTagNeedsClosingTag(const S: string): boolean;
begin
  case S of
    'area',
    'base',
    'br',
    'col',
    'command', //obsolete
    'embed',
    'frame', //not in html5
    'hr',
    'img',
    'input',
    'keygen', //obsolete
    'link',
    'menuitem', //obsolete
    'meta',
    'param',
    'source',
    'track',
    'wbr':
      Result:= false;
    else
      Result:= true;
  end;
end;

type
  TAcpIntegerArray = array of integer;

type
  { TAcp }

  TAcp = class
  private
    ListResult: TStringList;
    NeedBracketX: TAcpIntegerArray;
    procedure DoOnGetCompleteProp(Sender: TObject;
      AContent: TStringList;
      out ACharsLeft, ACharsRight: integer);
    procedure ApplyNeedBracketX;
    procedure InitMainLists;
  public
    Ed: TATSynEdit;
    ListEntities: TStringList;
    LastContext: TCompletionHtmlContext;
    LastChoices: array[TCompletionHtmlContext] of TStringList;
    procedure DoOnChoose(Sender: TObject; const ASnippetId: string; ASnippetIndex: integer);
    constructor Create; virtual;
    destructor Destroy; override;
  end;

var
  Acp: TAcp = nil;

function CompareHtmlItems(List: TStringList; Index1, Index2: Integer): Integer;
  //
  function GetStr(const SFrom: string): string;
  var
    Sep: TATStringSeparator;
  begin
    Sep.Init(SFrom, CompletionOps.ColumnsSep);
    //get 2nd column
    Sep.GetItemStr(Result);
    Sep.GetItemStr(Result);
    //delete from #1
    SDeleteFrom(Result, CompletionOps.SuffixSep);
  end;
  //
var
  LastChoices: TStringList;
  S1, S2: string;
  N1, N2: integer;
begin
  S1:= GetStr(List[Index1]);
  S2:= GetStr(List[Index2]);

  LastChoices:= Acp.LastChoices[Acp.LastContext];
  N1:= LastChoices.IndexOf(S1);
  N2:= LastChoices.IndexOf(S2);

  if (N1>=0) and (N2>=0) then
    exit(N1-N2);

  if (N1>=0) then
    exit(-1);
  if (N2>=0) then
    exit(1);

  Result:= strcomp(PChar(S1), PChar(S2));
end;

function SFindRegex(const SText, SRegex: string; NGroup: integer): string;
var
  R: TRegExpr;
begin
  Result:= '';
  R:= TRegExpr.Create;
  try
    R.ModifierS:= false;
    R.ModifierM:= true;
    R.ModifierI:= true;

    R.Expression:= SRegex;
    R.InputString:= SText;

    if R.ExecPos(1) then
      Result:= Copy(SText, R.MatchPos[NGroup], R.MatchLen[NGroup]);
  finally
    R.Free;
  end;
end;

function _StringEndsWithUnclosedQuote(const S: string; out AValueStr: string): boolean;
var
  i: integer;
begin
  Result:= false;
  AValueStr:= '';
  for i:= Length(S) downto 1 do
    case S[i] of
       '=':
         exit;
       '"', '''':
         begin
           AValueStr:= Copy(S, i+1, MaxInt);
           exit(true);
         end;
    end;
end;


function IsValidTagStart(const S: string): boolean;
var
  L: TStringList;
  i: integer;
begin
  Result:= false;
  if S='' then exit;

  L:= CompletionOpsHtml.ListOfTags;
  if L.Find(S, i) then
    exit(true);

  //some tag begins with S?
  for i:= 0 to L.Count-1 do
    if strlicomp(PChar(S), PChar(L[i]), Length(S))=0 then
      exit(true);
end;


function EditorGetHtmlContext(Ed: TATSynedit;
  APosX, APosY: integer;
  out ATagName, AAttrName, AValueStr: string;
  out ATagClosing: boolean;
  out ACharAfter: char): TCompletionHtmlContext;
const
  //regex to catch tag name at line start
  cRegexTagPart = '^\w+\b';
  cRegexTagOnly = '^\w*$';
  cRegexTagClose = '^/(\w*)$';
  //character class for all chars inside quotes
  cRegexChars = '[\s\w,\.:;\-\+\*\?=\(\)\[\]\{\}/\\\|~`\^\$&%\#@!\n]';
  //regex to catch attrib name, followed by "=" and not-closed quote, only at line end
  //this regex has $ at end so it's found just before the caret
  cRegexAttr = '\b([\w\-]+)\s*\=\s*([''"]' + cRegexChars + '*)?$';
  //regex group
  cGroupTagPart = 0;
  cGroupTagOnly = 0;
  cGroupTagClose = 1;
  cGroupAttr = 1;
var
  S: UnicodeString;
  NPrev, N: integer;
  bTagValid: boolean;
  ch: WideChar;
begin
  ATagName:= '';
  AAttrName:= '';
  AValueStr:= '';
  ATagClosing:= false;
  ACharAfter:= ' ';
  Result:= ctxNone;
  bTagValid:= false;

  //get str before caret
  S:= Ed.Strings.LineSub(APosY, 1, APosX);

  //detect HTML entity like &name;
  if (APosX>0) and (APosX<=Ed.Strings.LinesLen[APosY]) then
  begin
    N:= Length(S);
    while (N>0) and IsCharWordInIdentifier(S[N]) do
      Dec(N);
    if (N>0) and (S[N]='&') then
      exit(ctxEntity);
  end;

  //detect char after caret and next wordchars
  N:= APosX;
  repeat
    ch:= Ed.Strings.LineCharAt(APosY, N);
    if not IsCharWordA(ch) then
    begin
      ACharAfter:= ch;
      Break;
    end;
    Inc(N);
  until false;

  //add few previous lines to support multiline tags
  if APosY>0 then
  begin
    NPrev:= Max(0, APosY-CompletionOpsHtml.MaxLinesPerTag);
    for N:= APosY-1 downto NPrev do
      S:= Ed.Strings.Lines[N]+' '+S;
  end;

  //cut string before last "<" or ">" char
  N:= Length(S);
  while (N>0) and (S[N]<>'<') and (S[N]<>'>') do Dec(N);
  if N=0 then Exit;
  Delete(S, 1, N);

  ATagName:= LowerCase(SFindRegex(S, cRegexTagClose, cGroupTagClose));
  bTagValid:= IsValidTagStart(ATagName);
  if bTagValid then
  begin
    ATagClosing:= true;
    exit(ctxTags);
  end;

  ATagName:= LowerCase(SFindRegex(S, cRegexTagOnly, cGroupTagOnly));
  bTagValid:= IsValidTagStart(ATagName);
  if bTagValid then
    exit(ctxTags);

  ATagName:= LowerCase(SFindRegex(S, cRegexTagPart, cGroupTagPart));
  bTagValid:= IsValidTagStart(ATagName);
  if bTagValid then
  begin
    AAttrName:= LowerCase(SFindRegex(S, cRegexAttr, cGroupAttr));
    if AAttrName<>'' then
    begin
      if _StringEndsWithUnclosedQuote(S, AValueStr) then
      begin
        Result:= ctxValuesQuoted;
        if (ATagName='a') and (AAttrName='href') then
          Result:= ctxValueHref
        else
        if ((ATagName='frame') or (ATagName='iframe')) and (AAttrName='src') then
          Result:= ctxValueFrameSrc
        else
        if (ATagName='link') and (AAttrName='href') then
          Result:= ctxValueLinkHref
        else
        if (ATagName='script') and (AAttrName='src') then
          Result:= ctxValueScriptSrc
        else
        if ((ATagName='img') or (ATagName='input')) and (AAttrName='src') then
          Result:= ctxValueImageSrc
        else
        if (ATagName='audio') and (AAttrName='src') then
          Result:= ctxValueAudioSrc
        else
        if (ATagName='video') and (AAttrName='src') then
          Result:= ctxValueVideoSrc
        else
        if (ATagName='source') and (AAttrName='src') then
          Result:= ctxValueSourceSrc;
      end
      else
        Result:= ctxValues;
    end
    else
      Result:= ctxAttrs;
  end;
end;

{ TAcp }

procedure TAcp.DoOnGetCompleteProp(Sender: TObject;
  AContent: TStringList; out ACharsLeft, ACharsRight: integer);
  //
  procedure GetFileNames(AResult: TStringList; const AText, AFileMask: string);
  var
    bAddSlash: boolean;
  begin
    EditorGetDistanceToQuotes(Ed, ACharsLeft, ACharsRight, bAddSlash);
    CalculateCompletionFilenames(AResult,
      ExtractFileDir(Ed.FileName),
      AText,
      AFileMask,
      CompletionOpsHtml.PrefixDir,
      CompletionOpsHtml.PrefixFile,
      bAddSlash,
      false
      );
  end;
  //
var
  Caret: TATCaretItem;
  Context: TCompletionHtmlContext;
  EdLine: UnicodeString;
  s_word: atString;
  s_tag, s_attr, s_item, s_value,
  s_tag_bracket, s_tag_close: string;
  s_quote, s_space, s_equalchar: string;
  ok, bClosing: boolean;
  NextChar: char;
  L: TStringList;
  i: integer;
begin
  InitMainLists;
  AContent.Clear;
  ACharsLeft:= 0;
  ACharsRight:= 0;
  ListResult.Clear;

  Caret:= Ed.Carets[0];
  if not Ed.Strings.IsIndexValid(Caret.PosY) then exit;

  Context:= EditorGetHtmlContext(Ed,
    Caret.PosX,
    Caret.PosY,
    s_tag,
    s_attr,
    s_value,
    bClosing,
    NextChar);

  EditorGetCurrentWord(Ed,
    Caret.PosX,
    Caret.PosY,
    CompletionOpsHtml.NonWordChars,
    s_word,
    ACharsLeft,
    ACharsRight);

  case Context of
    ctxTags:
      begin
        L:= TStringList.Create;
        try
          CompletionOpsHtml.Provider.GetTags(L);

          for i:= 0 to L.Count-1 do
          begin
            s_item:= L[i];

            //special handle of some tags: a, img, link...
            if s_item='a' then
              s_item:= 'a'#1' href="'#1'"></a>'
            else
            if s_item='img' then
              s_item:= 'img'#1' src="'#1'">'
            else
            if s_item='link' then
              s_item:= 'link'#1' rel="stylesheet" type="text/css" href="'#1'">'
            else
            begin
              //usual handle of all tags
              s_tag_bracket:= '';
              s_tag_close:= '';
              if NextChar<>'>' then
              begin
                s_tag_bracket:= '>';
                if not bClosing and IsTagNeedsClosingTag(s_item) then
                  s_tag_close:= #1'</'+s_item+'>';
              end;
              s_item:= s_item+#1+s_tag_bracket+s_tag_close;
            end;

            //filter items
            if s_word<>'' then
            begin
              ok:= StartsText(s_word, s_item);
              if not ok then Continue;
            end;

            ListResult.Add(CompletionOpsHtml.PrefixTag+'|'+s_item);
          end;
        finally
          FreeAndNil(L);
        end;
      end;

    ctxAttrs:
      begin
        if NextChar='=' then
          s_equalchar:= ''
        else
          s_equalchar:= '=""';

        L:= TStringList.Create;
        try
          CompletionOpsHtml.Provider.GetTagProps(s_tag, L);

          //keep only items which begin with s_word
          for s_item in L do
          begin
            if s_word<>'' then
            begin
              ok:= StartsText(s_word, s_item);
              if not ok then Continue;
            end;

            ListResult.Add(s_tag+' '+CompletionOpsHtml.PrefixAttrib+'|'+s_item+#1+s_equalchar);
          end;
        finally
          FreeAndNil(L);
        end;
      end;

    ctxValues,
    ctxValuesQuoted:
      begin
        if Context=ctxValuesQuoted then
        begin
          s_quote:= '';
          s_space:= '';
        end
        else
        begin
          s_quote:= '"';
          s_space:= ' ';
        end;

        L:= TStringList.Create;
        try
          CompletionOpsHtml.Provider.GetTagPropValues(s_tag, s_attr, L);
          for s_value in L do
            ListResult.Add(s_attr+' '+CompletionOpsHtml.PrefixValue+'|'+s_quote+s_value+s_quote+#1+s_space);
        finally
          FreeAndNil(L);
        end;
      end;

    ctxEntity:
      begin
        EdLine:= Ed.Strings.Lines[Caret.PosY];
        i:= Caret.PosX+ACharsRight+1;
        if i<=Length(EdLine) then
        begin
          NextChar:= EdLine[i];
          if NextChar=';' then
            Inc(ACharsRight); //to replace old entity with ';'
        end;

        if not Assigned(ListEntities) then
        begin
          ListEntities:= TStringList.Create;
          if FileExists(CompletionOpsHtml.FilenameHtmlEntities) then
            ListEntities.LoadFromFile(CompletionOpsHtml.FilenameHtmlEntities);
        end;

        for s_value in ListEntities do
          if StartsText(s_word, s_value) then //case insensitive
            ListResult.Add(CompletionOpsHtml.PrefixEntity+'|'+s_value+';');
      end;

    ctxValueHref:
      begin
        GetFileNames(ListResult, s_value, CompletionOpsHtml.FileMaskHREF);
      end;

    ctxValueLinkHref:
      begin
        GetFileNames(ListResult, s_value, CompletionOpsHtml.FileMaskLinkHREF);
      end;

    ctxValueScriptSrc:
      begin
        GetFileNames(ListResult, s_value, CompletionOpsHtml.FileMaskScript);
      end;

    ctxValueFrameSrc:
      begin
        GetFileNames(ListResult, s_value, CompletionOpsHtml.FileMaskFrame);
      end;

    ctxValueImageSrc:
      begin
        GetFileNames(ListResult, s_value, CompletionOpsHtml.FileMaskPictures);
      end;

    ctxValueAudioSrc:
      begin
        GetFileNames(ListResult, s_value, CompletionOpsHtml.FileMaskAudio);
      end;

    ctxValueVideoSrc:
      begin
        GetFileNames(ListResult, s_value, CompletionOpsHtml.FileMaskVideo);
      end;

    ctxValueSourceSrc:
      begin
        GetFileNames(ListResult, s_value, CompletionOpsHtml.FileMaskSomeSrc);
      end;
  end;

  ListResult.CustomSort(@CompareHtmlItems);
  AContent.Assign(ListResult);
end;

constructor TAcp.Create;
begin
  inherited;
end;

procedure TAcp.InitMainLists;
var
  ctx: TCompletionHtmlContext;
begin
  if ListResult=nil then
  begin
    ListResult:= TStringList.Create;
    ListResult.TextLineBreakStyle:= tlbsLF;

    for ctx:= Low(ctx) to High(ctx) do
      LastChoices[ctx]:= TStringList.Create;
  end;
end;

destructor TAcp.Destroy;
var
  ctx: TCompletionHtmlContext;
begin
  for ctx:= Low(ctx) to High(ctx) do
    FreeAndNil(LastChoices[ctx]);
  FreeAndNil(ListResult);
  FreeAndNil(ListEntities);
  inherited;
end;

procedure TAcp.DoOnChoose(Sender: TObject; const ASnippetId: string;
  ASnippetIndex: integer);
var
  Sep: TATStringSeparator;
  Str: string;
  L: TStringList;
  N: integer;
begin
  InitMainLists;

  Sep.Init(ASnippetId, CompletionOps.SuffixSep);
  Sep.GetItemStr(Str);

  L:= LastChoices[LastContext];
  N:= L.IndexOf(Str);
  if N>=0 then
    L.Delete(N);
  L.Insert(0, Str);

  Acp.ApplyNeedBracketX;
end;

procedure TAcp.ApplyNeedBracketX;
var
  Caret: TATCaretItem;
  SLine: UnicodeString;
  iCaret: integer;
begin
  if Length(NeedBracketX)<Ed.Carets.Count then exit;

  for iCaret:= Ed.Carets.Count-1 downto 0 do
  begin
    Caret:= Ed.Carets[iCaret];
    if NeedBracketX[iCaret]<0 then Continue;
    if Ed.Strings.IsIndexValid(Caret.PosY) then
    begin
      SLine:= Ed.Strings.Lines[Caret.PosY];
      Insert('<', SLine, NeedBracketX[iCaret]+1);
      Ed.Strings.Lines[Caret.PosY]:= SLine;
      Caret.PosX:= Caret.PosX+1;
      Ed.DoCaretsShift(iCaret+1, Caret.PosX, Caret.PosY, 1, 0, Point(0, 0));
    end;
  end;

  Ed.DoEventChange(Ed.Carets[0].PosY);
  Ed.Update(true);

  SetLength(NeedBracketX, 0);
end;


procedure EditorCompletionNeedsLeadBracket(Ed: TATSynEdit; var Res: TAcpIntegerArray);
var
  Caret: TATCaretItem;
  iCaret: integer;
  S: UnicodeString;
  X: integer;
begin
  SetLength(Res, Ed.Carets.Count);
  for iCaret:= 0 to Ed.Carets.Count-1 do
  begin
    Res[iCaret]:= -1;
    Caret:= Ed.Carets[iCaret];
    if not Ed.Strings.IsIndexValid(Caret.PosY) then Continue;
    S:= Ed.Strings.Lines[Caret.PosY];
    if Length(S)=0 then Continue;
    X:= Caret.PosX;
    if X<=0 then Continue;
    if X>Length(S) then Continue;
    if not IsCharWordA(S[X]) then Continue;
    while (X>0) and IsCharWordA(S[X]) do Dec(X);
    if X=0 then
      Res[iCaret]:= 0
    else
    if IsCharSpace(S[X]) or (S[X]='>') then
      Res[iCaret]:= X;
  end;
end;

//TODO: delete this func
(*
function EditorCompletionNeedsLeadingAngleBracket(Ed: TATSynEdit;
  const S: UnicodeString;
  const AX, AY: integer): boolean;
var
  ch: WideChar;
  i: integer;
begin
  Result:= false;
  if AX>Length(S) then exit;
  if AX=0 then
    Result:= true
  else
  if Acp.LastContext<>ctxEntity then
  begin
    //check that before caret it's not bad position:
    //- someword after line start
    //- someword after ">"
    i:= AX;
    if (i>0) and (i<=Length(S)) and IsCharWordA(S[i]) then
    begin
      while (i>0) and IsCharWordA(S[i]) do Dec(i);
      if i=0 then exit;
      if S[i]='>' then exit;
    end;

    //check nearest non-space char lefter than caret
    i:= AX;
    while (i>0) and (S[i]=' ') do Dec(i);
    if i>0 then
    begin
      ch:= S[i];
      if (Pos(ch, '<="''/:.-,')=0) and not IsCharWord(ch, cDefaultNonWordChars) then
        Result:= true;
    end
    else
      Result:= true;
  end;
end;
*)

procedure DoEditorCompletionHtml(Ed: TATSynEdit);
var
  Caret: TATCaretItem;
  S_Tag, S_Attr, S_Value: string;
  bClosing: boolean;
  NextChar: char;
begin
  Acp.Ed:= Ed;

  if CompletionOpsHtml.Provider=nil then
    CompletionOpsHtml.Provider:= TATHtmlBasicProvider.Create(
      CompletionOpsHtml.FilenameHtmlList,
      CompletionOpsHtml.FilenameHtmlGlobals);

  with CompletionOpsHtml do
    if ListOfTags=nil then
    begin
      ListOfTags:= TStringList.Create;
      ListOfTags.Sorted:= true;
      ListOfTags.CaseSensitive:= false;
      Provider.GetTags(ListOfTags);
    end;

  if Ed.Carets.Count=0 then exit;
  Caret:= Ed.Carets[0];
  if not Ed.Strings.IsIndexValid(Caret.PosY) then exit;

  Acp.LastContext:= EditorGetHtmlContext(Ed,
    Caret.PosX,
    Caret.PosY,
    S_Tag,
    S_Attr,
    S_Value,
    bClosing,
    NextChar);

  //we are inside style="..." ? call CSS completions.
  if (Acp.LastContext in [ctxValues, ctxValuesQuoted]) and (S_Attr='style') then
  begin
    DoEditorCompletionCss(Ed);
    exit;
  end;

  SetLength(Acp.NeedBracketX, 0);
  if Acp.LastContext=ctxTags then
    EditorCompletionNeedsLeadBracket(Ed, Acp.NeedBracketX);

  { //TODO: delete this
  else
    //insert missing '<' if completion was called without it?
    if EditorCompletionNeedsLeadingAngleBracket(Ed, S, Caret.PosX, Caret.PosY) then
    begin
      Insert('<', S, Caret.PosX+1);
      Ed.Strings.Lines[Caret.PosY]:= S;
      Caret.PosX:= Caret.PosX+1;
      Ed.Update(true);
      Ed.DoEventChange;
    end;
    }

  EditorShowCompletionListbox(Ed, @Acp.DoOnGetCompleteProp,
    nil,
    @Acp.DoOnChoose,
    '',
    0,
    true //allow multi-carets in HTML like Sublime does
    );
end;

initialization

  Acp:= TAcp.Create;

  with CompletionOpsHtml do
  begin
    Provider:= nil;
    ListOfTags:= nil;
    FilenameHtmlList:= '';
    FilenameHtmlGlobals:= '';
    FilenameHtmlEntities:= '';
    FileMaskHREF:= AllFilesMask;
    FileMaskLinkHREF:= '*.css';
    FileMaskPictures:= '*.png;*.gif;*.jpg;*.jpeg;*.ico';
    FileMaskScript:= '*.js';
    FileMaskFrame:= '*.htm;*.html;*.php*;*.asp;*.aspx';
    FileMaskAudio:= '*.mp3;*.ogg;*.wav';
    FileMaskVideo:= '*.mp4;*.ogg;*.webm';
    FileMaskSomeSrc:= FileMaskAudio+';'+FileMaskVideo;
    PrefixTag:= 'tag';
    PrefixAttrib:= 'attrib';
    PrefixValue:= 'value';
    PrefixDir:= 'folder';
    PrefixFile:= 'file';
    PrefixEntity:= 'entity';
    MaxLinesPerTag:= 40;
    NonWordChars:= '+*=/\()[]{}<>"''.,:;~?!@#$%^&|`…'; // '-' is word char
  end;

finalization

  with CompletionOpsHtml do
  begin
    if Assigned(ListOfTags) then
      FreeAndNil(ListOfTags);
    if Assigned(Provider) then
      FreeAndNil(Provider);
  end;

  FreeAndNil(Acp);

end.

