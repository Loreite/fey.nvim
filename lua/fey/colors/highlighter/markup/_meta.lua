---@meta
---@alias FeyMarkupRange { line: number, start_col: number, end_col: number }

---@alias FeyMarkupParserType 'emphasis' | 'link' | 'latex' | 'date'

---@class FeyMarkupNode
---@field type FeyMarkupParserType
---@field char string
---@field id string
---@field seek_id string
---@field nestable boolean
---@field node TSNode
---@field range FeyMarkupRange
---@field self_contained? boolean
---@field metadata? table<string, any>

---@class FeyMarkupHighlight
---@field from FeyMarkupRange
---@field to FeyMarkupRange
---@field char string
---@field metadata? table<string, any>

---@class FeyMarkupPreparedHighlight
---@field start_line number
---@field start_col number
---@field end_col number
---@field hl_group string
---@field spell? boolean
---@field priority number
---@field conceal? boolean
---@field ephemeral boolean
---@field url? string

---@class FeyMarkupHighlighter
---@field parse_node fun(self: FeyMarkupHighlighter, node: TSNode, capture_name: string): FeyMarkupNode | false
---@field is_valid_start_node fun(self: FeyMarkupHighlighter, entry: FeyMarkupNode, bufnr: number): boolean
---@field is_valid_end_node fun(self: FeyMarkupHighlighter, entry: FeyMarkupNode, bufnr: number): boolean
---@field highlight fun(self: FeyMarkupHighlighter, highlights: FeyMarkupHighlight[], bufnr: number)
---@field prepare_highlights fun(self: FeyMarkupHighlighter, highlights: FeyMarkupHighlight[], source: number | string): FeyMarkupPreparedHighlight[]
