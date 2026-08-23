import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:omnigisto_pkg/metadata_read.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: TestScreen(),
    );
  }
}

class TestScreen extends StatefulWidget {
  const TestScreen({super.key});

  @override
  State<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends State<TestScreen> {
  String _logs = "Press button to start test...\n";

  Uint8List? _picBytes;
  Uint8List? _tileBytes;

  void _log(String message) {
    setState(() {
      _logs += "$message\n";
    });
    print(message);
  }

  void _pic(img.Image pic, String type) {

    final Uint8List? tmp = Uint8List.fromList(img.encodeJpg(pic));

    setState(() {
      _picBytes = tmp;
    });
    if (_picBytes == null) {
      _log(" NO ${type} Image Found");

    }
  }

  void _tile(img.Image tile) {
    final Uint8List? tmp = Uint8List.fromList(img.encodeJpg(tile));
    setState(() {
      _tileBytes = tmp;
    });
    if (_tileBytes == null) {
      _log(" NO tile Found");
    }

  }



  Future<void> _runTest() async {

    try {
      // 1. Coping from assets to gadgets file system
      // There's no need's  to do it in real scenario, I'm do it in test, because  using assets/  folder
      // add your file
      String realPath = 'assets/1.2.276.0.7230010.3.1.4.826242871.3100.1534335055.4381.svs';

      final byteData = await rootBundle.load(realPath);
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/test.svs');

      _log("tempDir ${tempDir.path}/test.svs");

      await file.create(recursive: true);


      await file.writeAsBytes(byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));



      _log("File saved: ${file.path}");

      // 2. Запускаем ваш код из пакета
      final svs = await openSvsFile(file.path);
      if (svs == null) {
        _log("Error opening SVS file");
        return;
      }

      _log("Short metadata reading...");
      final meta = await readSvsMetadata(svs);



      if (meta != null) {
        _log("short metadata tileWidth ${meta.tileWidth}, tileHeight ${meta.tileHeight}, height ${meta.height}, width ${meta.width}");
        _log("");
        _log("Full metadata reading...");
        SvsFullMetadata? fullMeta = await readFullSvsMetadata(svs);
        if (fullMeta != null) {
          _log("SVS layers found: ${fullMeta.levels.length}");
          for (var i = 0; i < fullMeta.levels.length; i++) {
            var level = fullMeta.levels[i];
            _log(
                "  Level $i: ${level.width}x${level.height}, Tile: ${level.tileWidth}x${level.tileHeight}, Comp: ${level.compression}");
          }
          _log("Associations: ${fullMeta.associations.keys.toList()}");
          fullMeta.associations.forEach((key, value) {
            _log("  $key: ${value.width}x${value.height}");
          });

          _log("\n--- original Image Extraction ---");
          for (var type in ['thumbnail', 'label', 'macro']) {
            final bytes = await extractSvsImage(svs, type);
            if (bytes != null) {
              _log("  Extracted $type: ${bytes.length} bytes");
            } else {
              _log("  Failed to extract $type");
            }
          }


          const showType = 'thumbnail';

          final img.Image? pic = await extractSvsImageAsImage(svs, showType);
          if (pic == null) {
            _log("  Failed to extract ${showType} pic");
          } else {
            _log(" Extracted ${showType} pic");
            _pic(pic, showType);
          }

          final img.Image? tile = await extractSvsTileAsImage(svs, 0, 0,0);

          if (tile == null) {
            _log("  Failed to extract tile");
          } else {
            _log(" Extracted tile");
            _tile(tile);
          }

        }
      }

      await svs.close();
      _log("Test OK!");

    } catch (e) {
      _log("Test ended with error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Package test')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Text(_logs),
            if (_picBytes != null)
              Text("!!!! ASSICIATED IMAGE !!!!!"),
            if (_picBytes != null)
              Image.memory(_picBytes!),
            SizedBox(height: 30,),
            if (_tileBytes != null)
              Text("!!!!ZERO LEVEL FIRST TILE !!!!!"),
            if (_tileBytes != null)
                Image.memory(_tileBytes!),
          ]
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _runTest,
        child: const Icon(Icons.play_arrow),
      ),
    );
  }
}