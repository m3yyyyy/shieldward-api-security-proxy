export interface ServerSentEvent {
  readonly event: string
  readonly data: string
}

interface LineEnding {
  readonly index: number
  readonly length: number
}

export class ServerSentEventDecoder {
  #buffer = ''
  #eventType = ''
  #dataLines: string[] = []

  push(chunk: string): ServerSentEvent[] {
    this.#buffer += chunk

    const events: ServerSentEvent[] = []

    while (true) {
      const ending = findLineEnding(this.#buffer)

      if (ending === undefined) {
        break
      }

      const line = this.#buffer.slice(0, ending.index)

      this.#buffer = this.#buffer.slice(
        ending.index + ending.length,
      )

      this.#processLine(line, events)
    }

    return events
  }

  finish(): void {
    // An incomplete event without a terminating blank line is
    // intentionally discarded.
    this.#buffer = ''
    this.#eventType = ''
    this.#dataLines = []
  }

  #processLine(
    line: string,
    events: ServerSentEvent[],
  ): void {
    if (line === '') {
      this.#dispatch(events)
      return
    }

    if (line.startsWith(':')) {
      return
    }

    const colonIndex = line.indexOf(':')

    const field =
      colonIndex === -1
        ? line
        : line.slice(0, colonIndex)

    let value =
      colonIndex === -1
        ? ''
        : line.slice(colonIndex + 1)

    if (value.startsWith(' ')) {
      value = value.slice(1)
    }

    switch (field) {
      case 'event':
        this.#eventType = value
        break

      case 'data':
        this.#dataLines.push(value)
        break

      default:
        break
    }
  }

  #dispatch(events: ServerSentEvent[]): void {
    if (this.#dataLines.length === 0) {
      this.#eventType = ''
      return
    }

    events.push({
      event:
        this.#eventType === ''
          ? 'message'
          : this.#eventType,
      data: this.#dataLines.join('\n'),
    })

    this.#eventType = ''
    this.#dataLines = []
  }
}

function findLineEnding(
  value: string,
): LineEnding | undefined {
  for (let index = 0; index < value.length; index += 1) {
    const character = value[index]

    if (character === '\n') {
      return {
        index,
        length: 1,
      }
    }

    if (character === '\r') {
      if (index + 1 === value.length) {
        return undefined
      }

      return {
        index,
        length: value[index + 1] === '\n' ? 2 : 1,
      }
    }
  }

  return undefined
}