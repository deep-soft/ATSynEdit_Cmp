{
Copyright (C) Alexey Torgashin, uvviewsoft.com
License: MPL 2.0 or LGPL
}
unit ATSynEdit_Cmp_CSS;

{$mode objfpc}{$H+}

interface

uses
  ATSynEdit,
  ATSynEdit_Cmp_CSS_Provider;

procedure DoEditorCompletionCss(AEdit: TATSynEdit);

type
  TATCompletionOptionsCss = record
    Provider: TATCssProvider;
    FilenameCssList: string; //from CudaText: data/autocompletespec/css_list.ini
    FilenameCssColors: string; //from CudaText: data/autocompletespec/css_colors.ini
    FilenameCssSelectors: string; //from CudaText: data/autocompletespec/css_sel.ini
    PrefixProp: string;
    PrefixAtRule: string;
    PrefixPseudo: string;
    LinesToLookup: integer;
    NonWordChars: UnicodeString;
    FileMaskPictures: string;
    PrefixDir: string;
    PrefixFile: string;
  end;

var
  CompletionOpsCss: TATCompletionOptionsCss;

implementation

uses
  SysUtils, Classes, Graphics,
  StrUtils, Math,
  ATSynEdit_Carets,
  ATSynEdit_RegExpr,
  ATSynEdit_Cmp_Filenames,
  ATSynEdit_Cmp_Form;

type
  { TAcp }

  TAcp = class
  private
    ListSel: TStringList; //CSS at-rules (@) and pseudo elements (:)
    procedure DoOnGetCompleteProp(Sender: TObject; AContent: TStringList;
      out ACharsLeft, ACharsRight: integer);
  public
    Ed: TATSynEdit;
    constructor Create; virtual;
    destructor Destroy; override;
  end;

var
  Acp: TAcp = nil;

type
  TCompletionCssContext = (
    CtxNone,
    CtxPropertyName,
    CtxPropertyValue,
    CtxSelectors,
    CtxURI
    );

function SFindRegex(const SText, SRegex: UnicodeString; NGroup: integer): string;
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

function EditorGetCaretInCurlyBrackets(Ed: TATSynEdit; APosX, APosY: integer): boolean;
var
  S: UnicodeString;
  X, Y: integer;
begin
  Result:= false;
  for Y:= APosY downto Max(0, APosY-CompletionOpsCss.LinesToLookup) do
  begin
    S:= Ed.Strings.Lines[Y];
    if Y=APosY then
      Delete(S, APosX+1, MaxInt);
    for X:= Length(S) downto 1 do
    begin
      if S[X]='{' then
        exit(true);
      if S[X]='}' then
        exit(false);
    end;
  end;
end;

procedure EditorGetCssContext(Ed: TATSynEdit; APosX, APosY: integer;
  out AContext: TCompletionCssContext; out ATag: string);
const
  //char class for all chars in css values
  cRegexChars = '[''"\w\s\.,:/~&%@!=\#\$\^\-\+\(\)\?]';
  //regex to catch css property name, before css attribs and before ":", at line end
  cRegexProp = '([\w\-]+):\s*' + cRegexChars + '*$';
  cRegexAtRule = '(@[a-z\-]*)$';
  cRegexSelectors = '\w+(:+[a-z\-]*)$';
  cRegexGroup = 1; //group 1 in (..)
  cRegexUri = 'url\(\s*[''"]?(' + '[\w\.,/~@!=\-]*' + ')$';
var
  S, S2: UnicodeString;
  NPos: integer;
begin
  AContext:= CtxNone;
  ATag:= '';

  S:= Ed.Strings.LineSub(APosY, 1, APosX);

  NPos:= RPos(' url(', S);
  if NPos=0 then
    NPos:= RPos(':url(', S);
  if NPos>0 then
  begin
    S2:= Copy(S, NPos+1, MaxInt);
    S2:= SFindRegex(S2, cRegexUri, 1);
    if S2<>'' then
    begin
      AContext:= CtxURI;
      ATag:= S2;
      exit;
    end;
  end;

  ATag:= SFindRegex(S, cRegexAtRule, cRegexGroup);
  if ATag<>'' then
  begin
    AContext:= CtxSelectors;
    exit;
  end;

  if EditorGetCaretInCurlyBrackets(Ed, APosX, APosY) then
  begin
    AContext:= CtxPropertyName;
    if S='' then
      exit;
    ATag:= SFindRegex(S, cRegexProp, cRegexGroup);
    if ATag<>'' then
      AContext:= CtxPropertyValue;
  end
  else
  begin
    ATag:= SFindRegex(S, cRegexSelectors, cRegexGroup);
    if ATag<>'' then
      AContext:= CtxSelectors;
  end;
end;

function IsQuoteRight(ch: WideChar): boolean; inline;
begin
  case ch of
    '"', '''', ')':
      Result:= true;
    else
      Result:= false;
  end;
end;

function IsQuoteLeftOrSlash(ch: WideChar): boolean; inline;
begin
  case ch of
    '"', '''', '/', '\', '(':
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
  while (i<=Len) and not IsQuoteRight(S[i]) do Inc(i);
  ARight:= i-X;

  i:= X;
  while (i>1) and (i<=Len) and not IsQuoteLeftOrSlash(S[i-1]) do Dec(i);
  ALeft:= Max(0, X-i);
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
      CompletionOpsCss.PrefixDir,
      CompletionOpsCss.PrefixFile,
      bAddSlash,
      false
      );
  end;
  //
var
  Caret: TATCaretItem;
  L: TStringList;
  s_word: UnicodeString;
  s_tag, s_item, s_val, s_valsuffix: string;
  context: TCompletionCssContext;
  ok: boolean;
begin
  AContent.Clear;
  ACharsLeft:= 0;
  ACharsRight:= 0;
  Caret:= Ed.Carets[0];

  EditorGetCssContext(Ed, Caret.PosX, Caret.PosY, context, s_tag);

  EditorGetCurrentWord(Ed,
    Caret.PosX, Caret.PosY,
    CompletionOpsCss.NonWordChars,
    s_word,
    ACharsLeft,
    ACharsRight);

  case context of
    CtxPropertyValue:
      begin
        L:= TStringList.Create;
        try
          CompletionOpsCss.Provider.GetValues(s_tag, L);
          for s_item in L do
          begin
            s_val:= s_item;

            //filter values by cur word (not case sens)
            if s_word<>'' then
            begin
              ok:= StartsText(s_word, s_val);
              if not ok then Continue;
            end;

            //handle values like 'rgb()', 'val()'
            if EndsStr('()', s_val) then
            begin
              SetLength(s_val, Length(s_val)-2);
              s_valsuffix:= '|()';
            end
            else
              s_valsuffix:= ''; //CompletionOps.SuffixSep+' ';

            AContent.Add(CompletionOpsCss.PrefixProp+' "'+s_tag+'"|'+s_val+s_valsuffix);
          end;
        finally
          FreeAndNil(L);
        end;
      end;

    CtxPropertyName:
      begin
        //if caret is inside property
        //  back|ground: left;
        //then we must replace "background: ", ie replace extra 2 chars
        s_item:= Ed.Strings.LineSub(Caret.PosY, Caret.PosX+ACharsRight+1, 2);
        if s_item=': ' then
          Inc(ACharsRight, 2);

        L:= TStringList.Create;
        try
          CompletionOpsCss.Provider.GetProps(L);
          for s_item in L do
          begin
            //filter by cur word (not case sens)
            if s_word<>'' then
            begin
              ok:= StartsText(s_word, s_item);
              if not ok then Continue;
            end;

            AContent.Add(CompletionOpsCss.PrefixProp+'|'+s_item+#1': ');
          end;
        finally
          FreeAndNil(L);
        end;
      end;

    CtxSelectors:
      begin
        ACharsLeft:= Length(s_tag);

        if s_tag[1]='@' then
          s_val:= CompletionOpsCss.PrefixAtRule
        else
        if s_tag[1]=':' then
          s_val:= CompletionOpsCss.PrefixPseudo
        else
          exit;

        for s_item in ListSel do
        begin
          if (s_tag='') or StartsText(s_tag, s_item) then
            AContent.Add(s_val+'|'+s_item);
        end;
      end;

    CtxURI:
      begin
        GetFileNames(AContent, s_tag, CompletionOpsCss.FileMaskPictures);
      end;
  end;
end;

constructor TAcp.Create;
begin
  inherited;
  ListSel:= TStringlist.create;
end;

destructor TAcp.Destroy;
begin
  FreeAndNil(ListSel);
  inherited;
end;

procedure DoEditorCompletionCss(AEdit: TATSynEdit);
begin
  Acp.Ed:= AEdit;

  if CompletionOpsCss.Provider=nil then
  begin
    CompletionOpsCss.Provider:= TATCssBasicProvider.Create(
      CompletionOpsCss.FilenameCssList,
      CompletionOpsCss.FilenameCssColors);
  end;

  //optional list, load only once
  if Acp.ListSel.Count=0 then
  begin
    if FileExists(CompletionOpsCss.FilenameCssSelectors) then
      Acp.ListSel.LoadFromFile(CompletionOpsCss.FilenameCssSelectors);
  end;

  EditorShowCompletionListbox(AEdit, @Acp.DoOnGetCompleteProp);
end;

initialization

  Acp:= TAcp.Create;

  with CompletionOpsCss do
  begin
    Provider:= nil;
    FilenameCssList:= '';
    FilenameCssColors:= '';
    FilenameCssSelectors:= '';
    PrefixProp:= 'css';
    PrefixAtRule:= 'at-rule';
    PrefixPseudo:= 'pseudo';
    LinesToLookup:= 50;
    NonWordChars:= '#!@.{};''"<>'; //don't include ':'
    FileMaskPictures:= '*.png;*.gif;*.jpg;*.jpeg;*.ico';
    PrefixDir:= 'folder';
    PrefixFile:= 'file';
  end;

finalization

  with CompletionOpsCss do
    if Assigned(Provider) then
      FreeAndNil(Provider);
  FreeAndNil(Acp);

end.

