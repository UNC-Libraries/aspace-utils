# ASpace EAD Batch Ingest Scripts

ARCHIVED. This project has been archived and is no longer being developed or supported because UNC's migration into ArchivesSpace is complete

These scripts rely on the presence of the [aspace-jsonmodel-from-format plugin](https://github.com/lyrasis/aspace-jsonmodel-from-format) in your instance of ArchivesSpace.
The plugin converts ead xml to json object model, which allows import into ArchivesSpace. These scripts need not run on the same instance as the aspace instance, we use http post calls to the api (http://your.aspaceinstance:8089/..., for instance)

## Prerequisites
- In your (remote or local) instance of aspace, install the aspace-jsonmodel-from-format plugin. Install info at:
[https://github.com/lyrasis/aspace-jsonmodel-from-format](https://github.com/lyrasis/aspace-jsonmodel-from-format)
- Full set of EAD files need to be in a local, accessible directory (specified in config.yml, an example is provided [here](config.yml.example)
- Ruby 2.2+.  This should work fine with MRI, jRuby, or whatever, as long as it supports all the dependencies.
## Installation
- Check out this repository
- Create config.yml file based on config.yml.example
- Optionally create an exclude list ('exclude_list.txt') based on exclude_list.txt.example
- Install dependencies via Bundler

    ``` shell
    gem install bundler # If not already installed
    cd aspace-utils
    bundle install
    ```

## Running the ingester
To run the ingester, place you EAD files in the directory specified in your config.yml, and then run:

``` shell
bundle exec ingest_aspace.rb
```

If you want to keep an eye on what it's doing, I recommend:

``` shell
watch tail ingestlog.log
```

The ingester populates two log files - ingestlog.log and error_responses

At Harvard, we've been running this under screen to keep this running over long periods of time.

## A cautionary note on max_concurrency
This script can do concurrent requests, but versions of ArchivesSpace prior to 1.5.2 had a race condition around creating Subjects/Agents/other shared fields.  If using any prior version, you MUST set max_concurrency to 1.

## Analysis script
There's also an "analyze_logs.rb" script provided, which can be used thusly:

```
bundle exec ruby analyze_logs.rb ingestlog.log error_responses > analysis.txt
```

It currently assumes that there is ONE and only ONE set of logs in each of those files - if you want to use the analysis script, you'll need to wipe ingestlog.log and error_responses between runs.

Note that passing more than two arguments will enter the script in interactive mode - you'll be thrown into a pry session with several interesting local variables defined.

| Name | Description| Type |
| ---- | ---------- | ---- |
| upload_failures | Failures to upload resulting from ASpace DB errors/java errors | Hash keyed by approximate cause with values being hashes keyed by eadid |
| four_hundreds | Errors that come from the EAD converter | Hash of errors keyed by eadid |
| five_hundreds | Errors from Apache or Java or gremlins | Hash of errors keyed by eadid |
| by_error | Big ole hash with 4XX, 5XX, and upload failures aggregated by proximate cause | Hash of hashes of arrays, keyed by error class -> proximate cause |
| ok | number of finding aids successfully ingested | integer |
| bad | number of finding aids that failed to ingest | integer |
| total | number of finding aids processed in total | integer |

## Notes
- repository ids can be found using the api (http://localhost:8089/repositories, for example); they must be parsed out
- really this should handle its own log rotation, sorry, PRs welcome or I'll get to it eventually.
