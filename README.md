# sqsd-local

A local version of `sqsd`, the daemon that runs in Elastic Beanstalk's _Worker
Environments_.

## Usage

```bash
Usage: sqsd-local WORKER_QUEUE_NAME [options]

Options:

  -h             --help                         Print this help message
  -V             --version                      Print the CLI version
  -u URL         --worker-url=URL               Specify the worker URL to send POST requests to (default: http://localhost:5000)
  -d NAME        --dead-letter-queue-name=NAME  Name of the SQS queue to send messages to which the worker failed processing (no default)
  -T NAME        --http-timeout=NAME            Timeout in seconds for the HTTP POST request to worker (default: 30)
  -C MEDIA_TYPE  --content-type=MEDIA_TYPE      Content-Type header value to use in HTTP POST request to worker (default: application/octet-stream)
                 --sqs-host=MEDIA_TYPE          SQS endpoint host (default: localhost)
                 --sqs-port=MEDIA_TYPE          SQS endpoint port (default: 9324)
                 --forked                       If messages should be POSTed to the worker concurrently (default: false)
```

## Install/Build

Requirements:

* [Stack](https://docs.haskellstack.org/en/stable/README/)
* The `stack path --bin-path` on your `PATH`

**Install from Hackage:**

```bash
stack install sqsd-local
```

**Install from source:**

```bash
git clone git@github.com:owickstrom/sqsd-local.git
cd sqsd-local
stack setup
stack install
```

## License

[Mozilla Public License Version 2.0](LICENSE)
