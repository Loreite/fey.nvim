---@meta

---@alias FeyCompletionContext { line: string, base?: string, fuzzy?: boolean, matcher?: fun(value?: string, pattern?: string): boolean }
---@alias FeyCompletionItem { word: string, menu: string }

---@class FeyCompletionSource
---@field get_name fun(self: FeyCompletionSource): string
---@field get_start fun(self: FeyCompletionSource, context: FeyCompletionContext): number | nil
---@field get_results fun(self: FeyCompletionSource, context: FeyCompletionContext): string[]
