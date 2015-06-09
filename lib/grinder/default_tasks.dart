library bwu_utils_dev.grinder.default_tasks;

import 'dart:io' as io;
import 'dart:async' show Future, Stream;
import 'package:bwu_dart_archive_downloader/bwu_dart_archive_downloader.dart';
import 'package:bwu_dart_archive_downloader/dart_update.dart';
import 'package:bwu_utils_dev/grinder.dart';
import 'package:bwu_utils_dev/testing_server.dart';
import 'package:grinder/grinder.dart';
export 'package:grinder/grinder.dart' show DefaultTask, Depends, Task, grind;
import 'package:pub_semver/pub_semver.dart';

// TODO(zoechi) check if version was incremented
// TODO(zoechi) check if CHANGELOG.md contains version

//@Task('Delete build directory')
//void clean() => defaultClean(context);

const sourceDirs = const ['bin', 'example', 'lib', 'test', 'tool', 'web'];
final existingSourceDirs =
    sourceDirs.where((d) => new io.Directory(d).existsSync()).toList();
final subProjects = getSubProjects();

main(List<String> args) => grind(args);

@Task('Run analyzer')
analyze() => analyzeTask();

@Task('Runn all tests')
test() => testTask(['vm', 'content-shell']);
// TODO(zoechi) fix to support other browsers
//'dartium', 'chrome', 'phantomjs', 'firefox'

@Task('Run all VM tests')
testVm() => testTask(['vm']);

@Task('Run all browser tests')
testWeb() => testTask(['content-shell']);

@DefaultTask('Check everything')
@Depends(analyze, checkFormat, lint, test)
check() => checkTask();

@Task('Check source code format')
checkFormat() => checkFormatTask(existingSourceDirs);

/// format-all - fix all formatting issues
@Task('Fix all source format issues')
format() => formatTask();

@Task('Run lint checks')
lint() => lintTask();

@Depends(travisPrepare, check, coverage)
@Task('Travis')
travis() => travisTask();

@Task('Gather and send coverage data.')
coverage() => coverageTask();

@Task('Set up Travis prerequisites')
travisPrepare() => travisPrepareTask();

Function analyzeTask = analyzeTaskImpl;

analyzeTaskImpl() => new PubApp.global('tuneup').run(['check']);

Function checkTask = checkTaskImpl;

checkTaskImpl() {
  run('pub', arguments: ['publish', '-n']);
  checkSubProjects();
}

Function coverageTask = coverageTaskImpl;

coverageTaskImpl() {
  final String coverageToken = io.Platform.environment['REPO_TOKEN'];

  if (coverageToken != null) {
    new PubApp.global('dart_coveralls').run(
        ['report', '--retry', '2', '--exclude-test-files', 'test/all.dart']);
  } else {
    log('Skipping coverage task: no environment variable `REPO_TOKEN` found.');
  }
}

Function formatTask = formatTaskImpl;

formatTaskImpl() => new PubApp.global('dart_style').run(
    ['-w']..addAll(existingSourceDirs), script: 'format');

Function lintTask = lintTaskImpl;

lintTaskImpl() => new PubApp.global('linter')
    .run(['--stats', '-ctool/lintcfg.yaml']..addAll(existingSourceDirs));

Function testTask = testTaskImpl;

testTaskImpl(List<String> platforms,
    {bool runPubServe: false, bool runSelenium: false}) async {
  final seleniumJar = io.Platform.environment['SELENIUM_JAR'];

  final environment = {};
  if (platforms.contains('content-shell')) {
    environment['PATH'] =
        '${io.Platform.environment['PATH']}:${downloadsInstallPath}/content_shell';
  }

  PubServe pubServe;
  SeleniumStandaloneServer selenium;
  final servers = <Future<RunProcess>>[];

  try {
    if (runPubServe) {
      pubServe = new PubServe();
      log('start pub serve');
      servers.add(pubServe.start(directories: const ['test']).then((_) {
        pubServe.stdout.listen((e) => io.stdout.add(e));
        pubServe.stderr.listen((e) => io.stderr.add(e));
      }));
    }
    if (runSelenium) {
      selenium = new SeleniumStandaloneServer();
      log('start Selenium standalone server');
      servers.add(selenium.start(seleniumJar, args: []).then((_) {
        selenium.stdout.listen((e) => io.stdout.add(e));
        selenium.stderr.listen((e) => io.stderr.add(e));
      }));
    }

    await Future.wait(servers);

    final args = [];
    if (runPubServe) {
      args.add('--pub-serve=${pubServe.directoryPorts['test']}');
    }
    new PubApp.local('test').run([]..addAll(platforms.map((p) => '-p${p}')),
        runOptions: new RunOptions(environment: environment));
  } finally {
    if (pubServe != null) {
      pubServe.stop();
    }
    if (selenium != null) {
      selenium.stop();
    }
  }
}

//  final chromeBin = '-Dwebdriver.chrome.bin=/usr/bin/google-chrome';
//  final chromeDriverBin = '-Dwebdriver.chrome.driver=/usr/local/apps/webdriver/chromedriver/2.15/chromedriver_linux64/chromedriver';

Function travisTask = () {};

Function travisPrepareTask = travisPrepareTaskImpl;

travisPrepareTaskImpl() async {
  log('travisPrepareTaskImpl');
  if (doInstallContentShell) {
    log('contentShell');
    await installContentShell();
    log('contentShell done');
  }
  String pubVar = io.Platform.environment['PUB'];
  if (pubVar == 'DOWNGRADE') {
    log('downgrade');
    Pub.downgrade();
    log('downgrade done');
  } else if (pubVar == 'UPGRADE') {
    log('upgrade');
    Pub.upgrade();
    log('upgrade done');
  } else {
    // Travis by default runs `pub get`
  }
}

bool doInstallContentShell = true;

String downloadsInstallPath = '_install';

DownloadChannel get channelFromTravisDartVersion {
  final travisVersion = io.Platform.environment['TRAVIS_DART_VERSION'];
  if (travisVersion == 'dev') return DownloadChannel.devRelease;
  return DownloadChannel.stableRelease;
}

Future<io.File> installContentShell() async {
  return installDartArtifact(new DartiumFile.contentShellZip(
          Platform.getFromSystemPlatform(prefer64bit: true)),
      new io.Directory(downloadsInstallPath), 'content_shell',
      channel: channelFromTravisDartVersion);
}

Future<io.File> installDartArtifact(
    DownloadFile downloadFile, io.Directory downloadDirectory, String extractAs,
    {DownloadChannel channel: DownloadChannel.stableRelease,
    String version: 'latest'}) async {
  log('download ${downloadFile}');
  assert(downloadFile != null);
  assert(channel != null);
  assert(version != null && version.isNotEmpty);
  final downloader = new DartArchiveDownloader(downloadDirectory);
  String versionDirectoryName = version;
  if (version != 'latest') {
    versionDirectoryName =
        await downloader.findVersion(channel, new Version.parse(version));
  }
  final uri = await channel.getUri(downloadFile, version: versionDirectoryName);
  final file = await downloader.downloadFile(uri);
  await installArchive(file, downloadDirectory,
      replaceRootDirectoryName: extractAs);
  return file;
}

typedef List<io.Directory> GetSubProjects();

GetSubProjects getSubProjects = getSubProjectsImpl;

List<io.Directory> getSubProjectsImpl() => io.Directory.current
    .listSync(recursive: true)
    .where((d) => d.path.endsWith('pubspec.yaml') &&
        d.parent.absolute.path != io.Directory.current.absolute.path)
    .map((d) => d.parent)
    .toList();

Function checkSubProjects = checkSubProjectsImpl;

void checkSubProjectsImpl() {
  subProjects.forEach((p) {
    log('=== check sub-project: ${p.path} ===');
    run('dart',
        arguments: ['-c', 'tool/grind.dart', 'check'],
        runOptions: new RunOptions(
            workingDirectory: p.path, includeParentEnvironment: true));
  });
}
