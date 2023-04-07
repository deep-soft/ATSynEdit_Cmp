{
Copyright (C) Alexey Torgashin, uvviewsoft.com
License: MPL 2.0 or LGPL
}
unit ATSynEdit_Cmp_Form;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics,
  Dialogs, ExtCtrls,
  LCLProc, LCLType,
  ATSynEdit,
  ATListbox;

type
  TATCompletionPropEvent = procedure (Sender: TObject;
    AContent: TStringList; out ACharsLeft, ACharsRight: integer) of object;
  TATCompletionResultEvent = procedure (Sender: TObject;
    const ASnippetId: string; ASnippetIndex: integer) of object;

{
AContent is a list of strings. Each string is '|'-separated items.
Usually item_0 is prefix to show,
        item_1 is actual text (inserted on Enter),
        item_2, item_3 etc are only to show in listbox.
e.g. 'func|FuncOne|'
     'func|FuncTwo|(param1, param2)'#9'Function help'
     'var|VarName1|'
     'var|VarName2|'#9'Some description'
Also item_1 can have suffixes after chr(1): text+#1+suffix_before_caret+#1+suffix_after_caret.
Also you can append #9'Text' to show a description in a tooltip out of the listbox.
}

procedure EditorShowCompletionListbox(AEd: TATSynEdit;
  AOnGetProp: TATCompletionPropEvent;
  AOnResult: TATCompletionResultEvent = nil;
  AOnChoose: TATCompletionResultEvent = nil;
  const ASnippetId: string = '';
  ASelectedIndex: integer = 0;
  AAllowCarets: boolean = false);

procedure EditorGetCurrentWord(Ed: TATSynEdit;
  APosX, APosY: integer;
  const ANonWordChars: UnicodeString;
  out AWord: UnicodeString;
  out ACharsLeft, ACharsRight: integer);

type
  { TFormATSynEditComplete }

  TFormATSynEditComplete = class(TForm)
    Listbox: TATListbox;
    TimerUpdater: TTimer;
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormShow(Sender: TObject);
    procedure FormUTF8KeyPress(Sender: TObject; var UTF8Key: TUTF8Char);
    procedure ListboxClick(Sender: TObject);
    procedure ListboxDrawItem(Sender: TObject; C: TCanvas; AIndex: integer;
      const ARect: TRect);
    procedure TimerUpdaterTimer(Sender: TObject);
  private
    { private declarations }
    FTimerClosing: TTimer;
    SList: TStringlist;
    FOnGetProp: TATCompletionPropEvent;
    FOnResult: TATCompletionResultEvent;
    FOnChoose: TATCompletionResultEvent;
    FEdit: TATSynEdit;
    FCharsLeft,
    FCharsRight: integer;
    FHintWnd: THintWindow;
    FSnippetId: string;
    FSelectedIndex: integer;
    FOldCaretStopUnfocused: boolean;
    FOldDimUnfocusedBack: integer;
    FOldSaved: boolean;
    FUpdateForCaret: TPoint;
    procedure DoHintHide;
    procedure DoHintShow(const AHint: string);
    procedure DoReplaceTo(const AStr: string; AWithBracket: boolean);
    procedure DoResult;
    procedure DoUpdate;
    function GetItemText(const AText: string; AIndex: integer): string;
    procedure GetResultText(out AText: string; out AWithBracket: boolean);
    procedure EditorOptionsSave;
    procedure EditorOptionsRestore;
    procedure TimerClosingTimer(Sender: TObject);
  public
    { public declarations }
    property Editor: TATSynEdit read FEdit write FEdit;
    property OnGetProp: TATCompletionPropEvent read FOnGetProp write FOnGetProp;

    //OnResult must handle: insertion of final result (and anything after insertion)
    //if OnResult is set, OnChoose won't be called
    property OnResult: TATCompletionResultEvent read FOnResult write FOnResult;

    //OnChoose must handle: moment _after_ insertion of final result
    property OnChoose: TATCompletionResultEvent read FOnChoose write FOnChoose;

    property SnippetId: string read FSnippetId write FSnippetId;
    property SelectedIndex: integer read FSelectedIndex write FSelectedIndex;
  end;

const
  cCompletionColumnCount = 5;

type
  TATCompletionUpDownAtEdge = (
    cudIgnore,
    cudWrap,
    cudCloseForm
    );

  TATCompletionOptions = record
    CommitIfSingleItem: boolean;
    ColorFontPrefix: TColor;
    ColorFontParams: TColor;
    CommitChars: string;
    CloseChars: string;
    IndexOfText: integer;
    IndexOfDesc: integer;
    ColumnsSep: char;
    HintSep: char;
    HintMultiLineSep: char;
    HintOnlyInTooltip: boolean;
    SuffixSep: char; //after completion value it can be 2 suffixes: value+sep+suffix1+sep+suffix2; and suffix2 won't shift caret.X
    AppendOpeningBracket: boolean;
    TrailingCharToShowAgain: char;
    ListSort: boolean;
    UpDownAtEdge: TATCompletionUpDownAtEdge;
    BorderSize: integer;
    FormWidth: integer;
    FormMaxVisibleItems: integer;
    HintWidth: integer;
    TextIndentLeftCol: integer;
    TextIndentRightCol: integer;
    TextIndent: integer;
    ClosingTimerInverval: integer;
    ShortcutForAutocomplete: TShortCut;
    CommandForShitchTab: integer;
  end;

const
  CompletionSignatureHTML = '<html>';

var
  CompletionOps: TATCompletionOptions;

var
  FormAutoCompletion: TFormATSynEditComplete = nil;

implementation

uses
  ATStrings,
  ATStringProc,
  ATStringProc_Separator,
  ATSynEdit_Carets,
  ATSynEdit_Commands,
  ATSynEdit_Cmp_RenderHTML,
  ATSynEdit_Keymap,
  ATFlatThemes,
  Math;

{$R *.lfm}

function EditorGetLefterWordChars(Ed: TATSynEdit; AX, AY: integer): integer;
var
  St: TATStrings;
  i: integer;
  SLine: UnicodeString;
begin
  Result:= 0;
  St:= Ed.Strings;
  if not St.IsIndexValid(AY) then exit;
  if AX>St.LinesLen[AY] then exit;
  SLine:= St.LineSub(AY, 1, AX);
  for i:= AX-1 downto 0 do
  begin
    if not IsCharWord(SLine[i+1], Ed.OptNonWordChars) then
      Break;
    Inc(Result);
  end;
end;

procedure EditorShowCompletionListbox(AEd: TATSynEdit;
  AOnGetProp: TATCompletionPropEvent;
  AOnResult: TATCompletionResultEvent = nil;
  AOnChoose: TATCompletionResultEvent = nil;
  const ASnippetId: string = '';
  ASelectedIndex: integer = 0;
  AAllowCarets: boolean = false);
begin
  if AEd.ModeReadOnly then exit;
  if AEd.Carets.Count>1 then
    if not AAllowCarets then exit;

  if FormAutoCompletion=nil then
    FormAutoCompletion:= TFormATSynEditComplete.Create(nil);

  FormAutoCompletion.Listbox.ItemIndex:= 0;
  FormAutoCompletion.Listbox.ItemTop:= 0;
  FormAutoCompletion.Editor:= AEd;
  FormAutoCompletion.SelectedIndex:= ASelectedIndex;
  FormAutoCompletion.SnippetId:= ASnippetId;
  FormAutoCompletion.OnGetProp:= AOnGetProp;
  FormAutoCompletion.OnResult:= AOnResult;
  FormAutoCompletion.OnChoose:= AOnChoose;
  FormAutoCompletion.DoUpdate;
end;

procedure TFormATSynEditComplete.DoReplaceTo(const AStr: string; AWithBracket: boolean);
var
  Caret: TATCaretItem;
  Pos, Shift, PosAfter: TPoint;
  StrText, Str1, Str2, StrToInsert: atString;
  Sep: TATStringSeparator;
  NCharsLeftNew: integer;
  iCaret: integer;
begin
  if AStr='' then exit;
  if Editor.Carets.Count=0 then exit;

  Sep.Init(AStr, CompletionOps.SuffixSep);
  Sep.GetItemStr(StrText);
  Sep.GetItemStr(Str1);
  Sep.GetItemStr(Str2);

  //must support multi-carets, for HTML
  Editor.Strings.BeginUndoGroup;
  try
    for iCaret:= 0 to Editor.Carets.Count-1 do
    begin
      Caret:= Editor.Carets[iCaret];
      Pos.X:= Caret.PosX;
      Pos.Y:= Caret.PosY;

      //updated count of word-chars lefter than caret;
      //it is different, when in CudaText user types fast and auto-completion auto-show triggers
      NCharsLeftNew:= EditorGetLefterWordChars(Editor, Pos.X, Pos.Y);

      FCharsLeft:= Min(Pos.X, FCharsLeft);
      if FCharsLeft<NCharsLeftNew then
        FCharsLeft:= NCharsLeftNew;
      Dec(Pos.X, FCharsLeft);

      Editor.Strings.TextDeleteRight(Pos.X, Pos.Y, FCharsLeft+FCharsRight, Shift, PosAfter, false);

      StrToInsert:= StrText+Str1+Str2;

      if AWithBracket then
        if Editor.Strings.TextSubstring(Pos.X, Pos.Y, Pos.X+1, Pos.Y)<>'(' then
        begin
          StrToInsert+= '()';
          Str2:= ')';
        end;

      Editor.Strings.TextInsert(Pos.X, Pos.Y, StrToInsert, false, Shift, PosAfter);

      //adjust markers/attrs
      Editor.UpdateCaretsAndMarkersOnEditing(iCaret+1,
        Pos,
        Pos,
        Point(Length(StrToInsert) - FCharsLeft-FCharsRight, 0),
        PosAfter
        );

      Caret.PosX:= Pos.X+Length(StrToInsert)-Length(Str2);
      Caret.EndX:= -1;
      Caret.EndY:= -1;
    end;
  finally
    Editor.Strings.EndUndoGroup;
    Editor.DoEventChange(Editor.Carets[0].PosY);
    Editor.Update(true);
  end;
end;

{ TFormATSynEditComplete }

procedure TFormATSynEditComplete.FormCreate(Sender: TObject);
begin
  SList:= TStringList.Create;
  SList.TextLineBreakStyle:= tlbsLF;
  FHintWnd:= THintWindow.Create(Self);
end;

procedure TFormATSynEditComplete.FormDeactivate(Sender: TObject);
begin
  Close;
  EditorOptionsRestore;
end;

procedure TFormATSynEditComplete.FormClose(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  DoHintHide;
  CloseAction:= caHide;

  //force focus to editor, fix CudaText issue #4111
  if FEdit.Visible and FEdit.Enabled and FEdit.CanFocus then
    FEdit.SetFocus;

  //veksha's fix for Win11 problem with Alt+Tab after auto-completion, CudaText issue #4964
  Parent:= Application.MainForm;
end;

procedure TFormATSynEditComplete.FormDestroy(Sender: TObject);
begin
  SList.Free;
end;

procedure TFormATSynEditComplete.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  NShortCut: TShortCut;
  KeyHistory: TATKeyArray;
  NCommand: integer;
begin
  case Key of
    VK_CONTROL,
    VK_SHIFT:
      Exit;
    VK_MENU:
      begin
        Key:= 0; //fix mainform loosing focus after pressing Alt/Alt in completion form
        Exit;
      end;
  end;

  if (Key=VK_UP) and (Shift=[]) then
  begin
    if Listbox.ItemIndex>0 then
      Listbox.ItemIndex:= Listbox.ItemIndex-1
    else
    case CompletionOps.UpDownAtEdge of
      cudWrap:
        Listbox.ItemIndex:= Listbox.ItemCount-1;
      cudCloseForm:
        Close;
    end;
    Key:= 0;
    exit
  end;

  if (Key=VK_DOWN) and (Shift=[]) then
  begin
    if Listbox.ItemIndex<Listbox.ItemCount-1 then
      Listbox.ItemIndex:= Listbox.ItemIndex+1
    else
    case CompletionOps.UpDownAtEdge of
      cudWrap:
        Listbox.ItemIndex:= 0;
      cudCloseForm:
        Close;
    end;
    Key:= 0;
    exit
  end;

  if (Key=VK_PRIOR) and (Shift=[]) then
  begin
    Listbox.ItemIndex:= Max(0, Listbox.ItemIndex-Listbox.VisibleItems);
    Key:= 0;
    exit
  end;

  if (Key=VK_NEXT) and (Shift=[]) then
  begin
    Listbox.ItemIndex:= Min(Listbox.ItemCount-1, Listbox.ItemIndex+Listbox.VisibleItems);
    Key:= 0;
    exit
  end;

  //in many editors, Home/End move caret to edge of the line, w/o listbox navigation
  if (Key=VK_HOME) and (Shift=[]) then
  begin
    Close;
    Editor.DoCommand(cCommand_KeyHome, cInvokeHotkey);
    Key:= 0;
    exit;
  end;

  if (Key=VK_END) and (Shift=[]) then
  begin
    Close;
    Editor.DoCommand(cCommand_KeyEnd, cInvokeHotkey);
    Key:= 0;
    exit;
  end;

  if (Key=VK_ESCAPE) and (Shift=[]) then
  begin
    Close;
    Key:= 0;
    exit
  end;

  if ((Key=VK_RETURN) or (Key=VK_TAB)) and (Shift=[]) then
  begin
    DoResult;
    Key:= 0;
    exit
  end;

  if (Key=VK_LEFT) and (Shift=[]) then
  begin
    Editor.DoCommand(cCommand_KeyLeft, cInvokeHotkey);
    DoUpdate;
    Key:= 0;
    exit
  end;

  if (Key=VK_RIGHT) and (Shift=[]) then
  begin
    Editor.DoCommand(cCommand_KeyRight, cInvokeHotkey);
    DoUpdate;
    Key:= 0;
    exit
  end;

  if (Key=VK_DELETE) and (Shift=[]) then
  begin
    Editor.DoCommand(cCommand_KeyDelete, cInvokeHotkey);
    DoUpdate;
    Key:= 0;
    exit
  end;

  if (Key=VK_BACK) and (Shift=[]) then
  begin
    Editor.DoCommand(cCommand_KeyBackspace, cInvokeHotkey);
    DoUpdate;
    Key:= 0;
    exit
  end;

  NShortCut:= KeyToShortCut(Key, Shift);
  if NShortCut=0 then exit;

  KeyHistory.Clear;
  NCommand:= Editor.Keymap.GetCommandFromShortcut(NShortcut, KeyHistory);
  case NCommand of
    0:
      exit;
    //some commands must be supported without closing the listbox
    cCommand_TextDeleteWordPrev, //Ctrl+BackSpace
    cCommand_TextDeleteWordNext: //Ctrl+Delete
      begin
        Editor.DoCommand(NCommand, cInvokeHotkey);
        DoUpdate;
        Key:= 0;
        exit;
      end;
    //some commands must be supported which close the listbox
    cCommand_Undo,
    cCommand_Redo,
    cCommand_KeyLeft_Sel, //Shift+Left
    cCommand_KeyRight_Sel, //Shift+Right
    cCommand_KeyHome_Sel, //Shift+Home
    cCommand_KeyEnd_Sel, //Shift+End
    cCommand_Clipboard_Begin..cCommand_Clipboard_End:
      begin
        Close;
        Editor.DoCommand(NCommand, cInvokeHotkey);
        Key:= 0;
        exit;
      end;
  end;

  if (NCommand=CompletionOps.CommandForShitchTab) then
  begin
    Close;
    Editor.DoCommand(NCommand, cInvokeHotkey);
    Key:= 0;
    exit;
  end;
end;

procedure TFormATSynEditComplete.FormShow(Sender: TObject);
begin
  if (FSelectedIndex>=0) and (FSelectedIndex<Listbox.ItemCount) then
    Listbox.ItemIndex:= FSelectedIndex;
end;

procedure TFormATSynEditComplete.FormUTF8KeyPress(Sender: TObject;
  var UTF8Key: TUTF8Char);
var
  bCommitChar, bCloseChar: boolean;
begin
  inherited;

  //backsp
  if (UTF8Key=#8) then
  begin
    FEdit.DoCommand(cCommand_KeyBackspace, cInvokeHotkey);
    DoUpdate;
    UTF8Key:= '';
    exit;
  end;

  //skip control Ascii chars
  if Ord(UTF8Key[1])<32 then Exit;

  bCommitChar:= Pos(UTF8Key, CompletionOps.CommitChars)>0;
  bCloseChar:= Pos(UTF8Key, CompletionOps.CloseChars)>0;

  if bCommitChar then
    DoResult;

  FEdit.DoCommand(cCommand_TextInsert, cInvokeHotkey, UTF8Decode(UTF8Key));

  if bCommitChar or bCloseChar then
    Close
  else
    DoUpdate;

  UTF8Key:= '';
end;

procedure TFormATSynEditComplete.ListboxClick(Sender: TObject);
begin
  DoResult;
end;

function TFormATSynEditComplete.GetItemText(const AText: string; AIndex: integer): string;
var
  Sep: TATStringSeparator;
  i: integer;
begin
  Sep.Init(AText, CompletionOps.ColumnsSep);
  for i:= 0 to AIndex do
    Sep.GetItemStr(Result);
end;

procedure TFormATSynEditComplete.GetResultText(out AText: string; out AWithBracket: boolean);
var
  N: integer;
  SDesc: string;
begin
  AText:= '';
  AWithBracket:= false;

  N:= Listbox.ItemIndex;
  if (N>=0) and (N<SList.Count) then
  begin
    AText:= GetItemText(SList[N], CompletionOps.IndexOfText);
    SDesc:= GetItemText(SList[N], CompletionOps.IndexOfDesc);

    AWithBracket:=
      CompletionOps.AppendOpeningBracket and
      SBeginsWith(SDesc, '(');
  end;
end;

procedure TFormATSynEditComplete.EditorOptionsSave;
begin
  if not FOldSaved then
  begin
    FOldSaved:= true;
    FOldCaretStopUnfocused:= Editor.OptCaretStopUnfocused;
    FOldDimUnfocusedBack:= Editor.OptDimUnfocusedBack;
    Editor.OptCaretStopUnfocused:= false;
    Editor.OptDimUnfocusedBack:= 0;
  end;
end;

procedure TFormATSynEditComplete.EditorOptionsRestore;
begin
  if Assigned(FEdit) then
  begin
    if FOldSaved then
    begin
      FOldSaved:= false;
      FEdit.OptCaretStopUnfocused:= FOldCaretStopUnfocused;
      FEdit.OptDimUnfocusedBack:= FOldDimUnfocusedBack;
    end;

    //make caret visible!
    FEdit.DoGotoCaret(cEdgeTop);
  end;
end;

procedure _TextOut(C: TCanvas; X, Y: integer; const Text: string);
begin
  if SBeginsWith(Text, CompletionSignatureHTML) then
    CanvasTextOutHTML(C, X, Y, Copy(Text, Length(CompletionSignatureHTML)+1, MaxInt))
  else
  begin
    C.Brush.Style:= bsSolid;
    C.TextOut(X, Y, Text);
  end;
end;

function _TextWidth(C: TCanvas; const Text: string): integer;
begin
  if SBeginsWith(Text, CompletionSignatureHTML) then
    Result:= CanvasTextWidthHTML(C, Copy(Text, Length(CompletionSignatureHTML)+1, MaxInt))
  else
    Result:= C.TextWidth(Text);
end;

procedure TFormATSynEditComplete.ListboxDrawItem(Sender: TObject; C: TCanvas;
  AIndex: integer; const ARect: TRect);
var
  Sep: TATStringSeparator;
  SLongItem, SItem, SHint: string;
  NSize, i: integer;
begin
  if (AIndex<0) or (AIndex>=SList.Count) then exit;
  SLongItem:= SList[AIndex];

  if AIndex=Listbox.ItemIndex then
    C.Brush.Color:= ATFlatTheme.ColorBgListboxSel
  else
    C.Brush.Color:= ATFlatTheme.ColorBgListbox;
  C.FillRect(ARect);

  C.Font.Name:= ATFlatTheme.FontName;
  C.Font.Size:= ATFlatTheme.DoScaleFont(ATFlatTheme.FontSize);

  //alternate listbox: OnResult is set, then 3 columns, tab-separated:
  //paint column1 at left,
  //paint column2 at right
  if Assigned(FOnResult) then
  begin
    Sep.Init(SLongItem, #9);
    Sep.GetItemStr(SItem);
    Sep.GetItemStr(SHint);

    //text
    C.Font.Color:= ATFlatTheme.ColorFontListbox;
    _TextOut(C,
      ARect.Left+CompletionOps.TextIndentLeftCol,
      ARect.Top,
      SItem
      );

    //prefix
    C.Font.Color:= CompletionOps.ColorFontPrefix;
    SHint+= ' ';
    _TextOut(C,
      ARect.Left+Listbox.ClientWidth-_TextWidth(C, SHint)-CompletionOps.TextIndentRightCol,
      ARect.Top,
      SHint
      );

    exit;
  end;

  //usual case, n columns, tab-char separates hint (in hint window)
  if Pos(CompletionOps.HintSep, SLongItem)>0 then
  begin
    SSplitByChar(SLongItem, CompletionOps.HintSep, SItem, SHint);
    if CompletionOps.HintOnlyInTooltip then
      SLongItem:= SItem;
    SHint:= StringReplace(SHint, CompletionOps.HintMultiLineSep, #10, [rfReplaceAll]);
    if AIndex=Listbox.ItemIndex then
      DoHintShow(SHint);
  end;

  NSize:= CompletionOps.TextIndentLeftCol;

  Sep.Init(SLongItem, CompletionOps.ColumnsSep);
  for i:= 0 to cCompletionColumnCount-1 do
  begin
    Sep.GetItemStr(SItem);

    if i=CompletionOps.IndexOfText then
      SItem:= SGetItem(SItem, CompletionOps.SuffixSep);

    if i=CompletionOps.IndexOfText then
      C.Font.Color:= ATFlatTheme.ColorFontListbox
    else
    if i=CompletionOps.IndexOfDesc then
      C.Font.Color:= CompletionOps.ColorFontParams
    else
      C.Font.Color:= CompletionOps.ColorFontPrefix;

    _TextOut(C,
      ARect.Left+NSize,
      ARect.Top,
      SItem
      );
    Inc(NSize, _TextWidth(C, SItem)+CompletionOps.TextIndent);
  end;
end;

procedure TFormATSynEditComplete.DoResult;
var
  Str: string;
  bWithBracket: boolean;
begin
  Str:= '';
  bWithBracket:= false;

  if Assigned(FOnResult) then
    FOnResult(Self, FSnippetId, Listbox.ItemIndex)
  else
  begin
    GetResultText(Str, bWithBracket);
    DoReplaceTo(Str, bWithBracket);

    if Assigned(FOnChoose) then
      FOnChoose(Self, Str, Listbox.ItemIndex);
  end;

  //for HTML: if inserted 'value=""' we must move caret lefter
  if SEndsWith(Str, '=""') then
    Editor.DoCommand(cCommand_KeyLeft, cInvokeInternal);

  if SEndsWith(Str, CompletionOps.TrailingCharToShowAgain) then
  begin
    DoUpdate;
  end
  else
    Close;
end;

procedure TFormATSynEditComplete.DoUpdate;
var
  Caret: TATCaretItem;
  RectMon: TRect;
  NewFormWidth, NewFormHeight, TempY: integer;
  NewFormPos, Pnt: TPoint;
begin
  Color:= ATFlatTheme.ColorBgListbox;

  SList.Clear;
  if Assigned(FOnGetProp) then
    FOnGetProp(Editor, SList, FCharsLeft, FCharsRight);

  Caret:= Editor.Carets[0];
  FUpdateForCaret.X:= Caret.PosX;
  FUpdateForCaret.Y:= Caret.PosY;

  if SList.Count=0 then
  begin
    //instead of 'Close' run the timer, to avoid hiding/showing when user presses Left/Right arrow in editor
    if FTimerClosing=nil then
    begin
      FTimerClosing:= TTimer.Create(Self);
      FTimerClosing.Interval:= CompletionOps.ClosingTimerInverval;
      FTimerClosing.OnTimer:= @TimerClosingTimer;
    end;
    FTimerClosing.Enabled:= false;
    FTimerClosing.Enabled:= true;

    exit
  end;

  if Assigned(FTimerClosing) then
    FTimerClosing.Enabled:= false;

  if SList.Count=1 then
    if CompletionOps.CommitIfSingleItem then
    begin
      DoResult;
      exit
    end;
  if CompletionOps.ListSort then SList.Sort;

  Listbox.VirtualItemCount:= SList.Count;
  Listbox.ItemIndex:= 0;
  Listbox.BorderSpacing.Around:= CompletionOps.BorderSize;
  Listbox.Invalidate;
  Listbox.UpdateItemHeight;

  Pnt.X:= Max(0, Caret.PosX-FCharsLeft);
  Pnt.Y:= Caret.PosY;
  Pnt:= Editor.CaretPosToClientPos(Pnt);
  Inc(Pnt.Y, Editor.TextCharSize.Y);
  NewFormPos:= Editor.ClientToScreen(Pnt);

  RectMon:= Screen.MonitorFromPoint(NewFormPos).WorkareaRect;

  NewFormWidth:= CompletionOps.FormWidth;
  NewFormHeight:= Min(CompletionOps.FormMaxVisibleItems, Listbox.ItemCount)*Listbox.ItemHeight + 2*Listbox.BorderSpacing.Around + 1;

  //check that form fits on the bottom
  if NewFormPos.Y+NewFormHeight>= RectMon.Bottom then
  begin
    TempY:= NewFormPos.Y-Editor.TextCharSize.Y-NewFormHeight;
    if TempY>=RectMon.Top then
      NewFormPos.Y:= TempY;
  end;

  EditorOptionsSave;

  //check that form fits on the right
  NewFormPos.X:= Max(RectMon.Left, Min(NewFormPos.X, RectMon.Right-NewFormWidth));

  if Application.MainForm.FormStyle in [fsStayOnTop, fsSystemStayOnTop] then
    FormStyle:= Application.MainForm.FormStyle;

  SetBounds(NewFormPos.X, NewFormPos.Y, NewFormWidth, NewFormHeight);
  Parent:= nil; //veksha's fix (part 2) for CudaText issue #4964
  Show;
end;


procedure EditorGetCurrentWord(Ed: TATSynEdit;
  APosX, APosY: integer;
  const ANonWordChars: UnicodeString;
  out AWord: UnicodeString;
  out ACharsLeft, ACharsRight: integer);
var
  str: atString;
  n: integer;
begin
  AWord:= '';
  ACharsLeft:= 0;
  ACharsRight:= 0;

  if not Ed.Strings.IsIndexValid(APosY) then exit;
  str:= Ed.Strings.Lines[APosY];

  n:= APosX;
  if (n>Length(str)) then exit;

  while (n>0) and (IsCharWord(str[n], ANonWordChars)) do
  begin
    AWord:= str[n]+AWord;
    Dec(n);
    Inc(ACharsLeft);
  end;

  n:= APosX;
  while (n<Length(str)) and (IsCharWord(str[n+1], ANonWordChars)) do
  begin
    Inc(n);
    Inc(ACharsRight);
  end;
end;

procedure TFormATSynEditComplete.DoHintShow(const AHint: string);
var
  P: TPoint;
  R: TRect;
begin
  R:= FHintWnd.CalcHintRect(CompletionOps.HintWidth, AHint, nil);

  P:= ClientToScreen(Point(Width, 0));
  OffsetRect(R, P.X, P.Y);

  FHintWnd.ActivateHint(R, AHint);
  FHintWnd.Invalidate; //for Win
  Editor.Invalidate; //for Win
end;

procedure TFormATSynEditComplete.DoHintHide;
begin
  if Assigned(FHintWnd) then
    FHintWnd.Hide;
end;

procedure TFormATSynEditComplete.TimerClosingTimer(Sender: TObject);
begin
  FTimerClosing.Enabled:= false;
  TimerUpdater.Enabled:= false;
  Close;
end;

procedure TFormATSynEditComplete.TimerUpdaterTimer(Sender: TObject);
{
this timer is needed very much. if user types fast + CudaText autocompletion auto-show works.
on typing 2-3 chars _fast_, form can be shown at the moment of only 1st char typed.
form must detect that additional chars were typed.
}
var
  Caret: TATCaretItem;
  NewPos: TPoint;
begin
  if not Visible then exit;
  if Editor.Carets.Count=0 then exit;

  Caret:= Editor.Carets[0];
  NewPos.X:= Caret.PosX;
  NewPos.Y:= Caret.PosY;
  if NewPos<>FUpdateForCaret then
    DoUpdate;
end;



initialization

  FillChar(CompletionOps, SizeOf(CompletionOps), 0);
  with CompletionOps do
  begin
    CommitIfSingleItem:= false;
    ColorFontPrefix:= clPurple;
    ColorFontParams:= clGray;
    CommitChars:= ' .,;''"';
    CloseChars:= '<>()[]{}=';
    IndexOfText:= 1;
    IndexOfDesc:= 2;
    ColumnsSep:= '|';
    HintSep:= #9;
    HintMultiLineSep:= #2;
    HintOnlyInTooltip:= true;
    SuffixSep:= #1;
    AppendOpeningBracket:= true;
    TrailingCharToShowAgain:= '/';
    ListSort:= false;
    UpDownAtEdge:= cudWrap;
    BorderSize:= 4;
    FormWidth:= 500;
    FormMaxVisibleItems:= 12;
    HintWidth:= 400;
    TextIndentLeftCol:= 3;
    TextIndentRightCol:= 0; //we add ' ' to right col to emulate right indent
    TextIndent:= 8;
    ClosingTimerInverval:= 300;
    ShortcutForAutocomplete:= 0;
  end;

finalization

  if Assigned(FormAutoCompletion) then
    FormAutoCompletion.Free;

end.

