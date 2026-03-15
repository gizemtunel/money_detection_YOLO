import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:typed_data';
import 'dart:ui' as ui; 
import 'package:image/image.dart' as img;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(),
    home: ParaSayarApp(cameras: cameras),
  ));
}

class ParaSayarApp extends StatefulWidget {
  final List<CameraDescription> cameras;
  const ParaSayarApp({super.key, required this.cameras});

  @override
  State<ParaSayarApp> createState() => _ParaSayarAppState();
}

class _ParaSayarAppState extends State<ParaSayarApp> {
  late CameraController controller;
  Interpreter? _interpreter;
  bool isAnalyzing = false;
  
  String resultText = "HAZIR";
  String subText = "Para tespiti için butona basın"; 
  double totalAmount = 0.0;
  Map<String, int> counts = {};

  final List<String> labels = ["100 TL", "10 TL", "200 TL", "20 TL", "50 TL", "5 TL"];
  final List<double> values = [100.0, 10.0, 200.0, 20.0, 50.0, 5.0];

  @override
  void initState() {
    super.initState();
    _loadModel();
    controller = CameraController(widget.cameras[0], ResolutionPreset.medium, enableAudio: false);
    controller.initialize().then((_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/best_float16.tflite');
    } catch (e) {
      print("Model yüklenemedi: $e");
    }
  }

  double calculateIoU(ui.Rect a, ui.Rect b) {
    ui.Rect intersection = a.intersect(b);
    if (intersection.width <= 0 || intersection.height <= 0) return 0.0;
    double intersectionArea = intersection.width * intersection.height;
    double unionArea = (a.width * a.height) + (b.width * b.height) - intersectionArea;
    return intersectionArea / unionArea;
  }

  Future<void> analyzeMoney() async {
    if (isAnalyzing || _interpreter == null) return;
    setState(() { 
      isAnalyzing = true; 
      resultText = "ANALİZ EDİLİYOR...";
    });

    try {
      final XFile photo = await controller.takePicture();
      final Uint8List bytes = await photo.readAsBytes();
      img.Image? originalImage = img.decodeImage(bytes);
      img.Image resizedImage = img.copyResize(originalImage!, width: 640, height: 640);

      var input = Float32List(1 * 640 * 640 * 3);
      int pixelIndex = 0;
      for (var y = 0; y < 640; y++) {
        for (var x = 0; x < 640; x++) {
          var pixel = resizedImage.getPixel(x, y);
          input[pixelIndex++] = pixel.r / 255.0;
          input[pixelIndex++] = pixel.g / 255.0;
          input[pixelIndex++] = pixel.b / 255.0;
        }
      }

      var output = List<double>.filled(1 * 10 * 8400, 0).reshape([1, 10, 8400]);
      _interpreter!.run(input.buffer.asUint8List(), output);

      List<ui.Rect> candidateBoxes = [];
      List<double> candidateScores = [];
      List<int> candidateClasses = [];

      for (var i = 0; i < 8400; i++) {
        double maxScore = 0;
        int bestClass = -1;
        for (int c = 0; c < 6; c++) {
          double score = output[0][c + 4][i];
          if (score > maxScore) {
            maxScore = score;
            bestClass = c;
          }
        }

        if (maxScore > 0.45) {
          double cx = output[0][0][i];
          double cy = output[0][1][i];
          double w = output[0][2][i];
          double h = output[0][3][i];
          candidateBoxes.add(ui.Rect.fromLTWH(cx - w / 2, cy - h / 2, w, h));
          candidateScores.add(maxScore);
          candidateClasses.add(bestClass);
        }
      }

      List<int> finalIndices = [];
      List<int> sortedIndices = List.generate(candidateScores.length, (i) => i)
        ..sort((a, b) => candidateScores[b].compareTo(candidateScores[a]));

      while (sortedIndices.isNotEmpty) {
        int bestIdx = sortedIndices.removeAt(0);
        finalIndices.add(bestIdx);
        sortedIndices.removeWhere((idx) => calculateIoU(candidateBoxes[bestIdx], candidateBoxes[idx]) > 0.4);
      }

      double tempTotal = 0;
      Map<String, int> tempCounts = {};
      double singleConfidence = 0;
      String singleLabel = "";

      for (int idx in finalIndices) {
        String label = labels[candidateClasses[idx]];
        tempCounts[label] = (tempCounts[label] ?? 0) + 1;
        tempTotal += values[candidateClasses[idx]];
        
        if (finalIndices.length == 1) {
          singleLabel = label;
          singleConfidence = candidateScores[idx] * 100;
        }
      }

      setState(() {
        totalAmount = tempTotal;
        counts = tempCounts;

        if (finalIndices.isEmpty) {
          resultText = "BOŞ";
          subText = "Herhangi bir para tespit edilemedi.";
        } else if (finalIndices.length == 1) {
          resultText = singleLabel;
          subText = "DOĞRULUK: %${singleConfidence.toStringAsFixed(1)}";
        } else {
          resultText = "TOPLAM TUTAR";
          subText = counts.entries.map((e) => "${e.value}x ${e.key}").join(" • ");
        }
      });

    } catch (e) {
      setState(() => resultText = "HATA");
    } finally {
      setState(() => isAnalyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!controller.value.isInitialized) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          CameraPreview(controller),
          Positioned(
            bottom: 40, left: 20, right: 20,
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(25),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: Colors.white10, width: 2),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      
                      Text(
                        resultText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),

                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 15),
                        height: 4,
                        width: 100,
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.red.withOpacity(0.5),
                              blurRadius: 5,
                            )
                          ]
                        ),
                      ),

                      Text(
                        subText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                      ),

                      if (totalAmount > 0 && finalIndicesLength() > 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 15),
                          child: Text(
                            "${totalAmount.toInt()} TL",
                            style: const TextStyle(
                              fontSize: 65,
                              fontWeight: FontWeight.w900,
                              color: Colors.greenAccent,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 25),
                FloatingActionButton.large(
                  onPressed: analyzeMoney,
                  backgroundColor: Colors.greenAccent,
                  child: isAnalyzing 
                    ? const CircularProgressIndicator(color: Colors.black) 
                    : const Icon(Icons.center_focus_strong, size: 45, color: Colors.black),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  int finalIndicesLength() {
    return counts.values.fold(0, (sum, item) => sum + item);
  }

  @override
  void dispose() {
    controller.dispose();
    _interpreter?.close();
    super.dispose();
  }
}