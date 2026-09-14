---@meta

---@class FeyLinkType
---@field get_name fun(self: FeyLinkType): string
---@field follow fun(self: FeyLinkType, link: string): boolean
---@field autocomplete fun(self: FeyLinkType, context: FeyCompletionContext): string[]
