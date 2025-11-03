# config/.credo.exs
%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: [
        {Credo.Check.Readability.LargeNumbers, only_greater_than: 86400},
        {Credo.Check.Readability.ParenthesesOnZeroArityDefs, parens: true},
        {Credo.Check.Design.TagTODO, exit_status: 0},
        {Credo.Check.Refactor.LongQuoteBlocks, []},
        {Credo.Check.Refactor.Nesting, max_nesting: 3},
        {Credo.Check.Readability.ImplTrue, []}
      ]
    }
  ]
}
