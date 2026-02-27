# ZehnTage

Only ten days to learn German vocab? ZehnTage ("ten days" in German) is a Neovim plugin that shows word definitions with etymology and usage notes to aid memorization, and automatically exports them as TSV for Anki.

![Screenshot](shot.png)

## Installation

LazyVim(recommended):

```lua
{
    "30be/zehntage",
    opts = {}, -- no opts are available.
    ft = { "markdown", "text" },
    keys = {
        { "K", "<cmd>ZehnTage<CR>", desc = "ZehnTage add word" }, -- the same as hinting is often set up
        { "<leader>zc", "<cmd>ZehnTageClear<CR>", desc = "ZehnTage clear word" },
    },
},
```

Set the `GEMINI_API_KEY` environment variable and you're good to go.
It uses Gemini 2.5 Flash Lite — fast enough to feel instant, smart enough for the task, and essentially free.

The entire plugin is a single file: [lua/zehntage.lua](lua/zehntage.lua).

The initial prompt is [included](PROMPT.md) (Claude Opus 4.6).

## Anki export

In Anki, click "Import File" and select `~/.local/share/nvim/zehntage_words.tsv`. Make sure to use a compatible card type.
