# Konishi

Named after the Konishi Polis in Greg Egan's [*Diaspora*](https://www.gregegan.net/DIASPORA/DIASPORA.html), this is a harness for LLMs. I built it around my own workflows for interacting with language models, managing local servers, and integrating various tools for language learning and research. It only contains the features I personally need, as to not overwhelm local LLMs with unnecessary complexity. It is lightweight by design and uses a sophisticated memory collection and injection mechanism to build a locally stored and contextually aware profile of the user.

It can set up and run local servers using [mlx-lm](https://github.com/ml-explore/mlx-lm), [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) (both built on Apple's [MLX](https://github.com/ml-explore/mlx)), or [IncoAI's Splash Engine](https://github.com/incoai/splash) for high-performance Qwen inference. I use it for language learning too: it suggests vocabulary and grammar, keeps track of progress, and handles spaced repetition. There's a voice mode as well, so you can talk to the model, interrupt it mid answer, and steer it while it's still going.

## Running it

Konishi needs macOS 26 or later. To build and launch it from this repo, you'll need Swift 6.2:

```sh
./run.sh
```

The local MLX and Splash server options are aimed at Apple silicon. Some of the server installers also expect Homebrew.

## A note on where things go

Konishi defaults to a local chat endpoint, but you can point chat, audio, or embeddings at other compatible servers. Requests, including prompts and any attached content, go to whichever endpoint you configure. Web research also sends queries to DuckDuckGo and fetches result pages, so using a local model doesn't make the whole app offline. Check your endpoints and enabled tools before sending anything sensitive.

Licensed under GPL-3.0; see [LICENSE](./LICENSE).
