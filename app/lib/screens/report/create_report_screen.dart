import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../services/api.dart';
import '../../services/location.dart';
import '../../theme.dart';
import '../../widgets/agency_sheet.dart';
import '../../widgets/common.dart';
import 'extraction_confirm_screen.dart';
import 'location_picker_screen.dart';

/// "Lapor bencana" (5.5): free text (with the keyboard's own dictation, FR-2.2)
/// or a structured form, a location field that is separate from the text from
/// the start (GPS or pin on map), optional photos and a contact number.
class CreateReportScreen extends StatefulWidget {
  const CreateReportScreen({super.key});

  @override
  State<CreateReportScreen> createState() => _CreateReportScreenState();
}

class _CreateReportScreenState extends State<CreateReportScreen> {
  final _text = TextEditingController();
  final _address = TextEditingController();
  final _contact = TextEditingController();
  final _formLocation = TextEditingController();
  final _formAccess = TextEditingController();
  final _formNeeds = TextEditingController();

  bool _formMode = false;
  String _incident = 'kebakaran permukiman';
  LatLng? _location;
  bool _manualLocation = false;
  bool _locating = false;
  final List<String> _photos = [];
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _useGps();
  }

  @override
  void dispose() {
    for (final c in [_text, _address, _contact, _formLocation, _formAccess, _formNeeds]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _useGps() async {
    setState(() => _locating = true);
    final loc = await context.read<LocationService>().refresh();
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (loc != null) {
        _location = loc;
        _manualLocation = false;
      }
    });
    if (loc == null) showMessage('Lokasi GPS tidak tersedia. Pilih lokasi di peta.', error: true);
  }

  Future<void> _pickOnMap() async {
    final picked = await Navigator.push<LatLng>(
      context,
      MaterialPageRoute(builder: (_) => LocationPickerScreen(initial: _location)),
    );
    if (picked != null) {
      setState(() {
        _location = picked;
        _manualLocation = true;
      });
    }
  }

  Future<void> _addPhoto(ImageSource source) async {
    try {
      final file = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
      if (file == null) return;
      setState(() => _uploading = true);
      final url = await Api.instance.uploadPhoto(file.path);
      setState(() => _photos.add(url));
    } catch (e) {
      showError(e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// The backend's form schema is just {title, description} and it infers the
  /// incident type from keywords in the description, so the chosen type goes
  /// into the description too -- otherwise it would default to "kebakaran".
  Json _structuredBody() {
    final location = _formLocation.text.trim();
    final access = _formAccess.text.trim();
    final needs = _formNeeds.text.trim();
    final incident = _incident[0].toUpperCase() + _incident.substring(1);
    return {
      'title': location.isEmpty ? incident : '$incident di $location',
      'description': [
        'Jenis kejadian: $incident.',
        if (location.isNotEmpty) 'Lokasi: $location.',
        if (access.isNotEmpty) 'Kondisi akses: $access.',
        if (needs.isNotEmpty) 'Bantuan yang dibutuhkan: $needs.',
      ].join(' '),
    };
  }

  Future<void> _submit() async {
    if (_location == null) {
      showMessage('Tentukan lokasi kejadian terlebih dahulu.', error: true);
      return;
    }
    if (!_formMode && _text.text.trim().length < 5) {
      showMessage('Ceritakan kejadiannya minimal satu kalimat, atau pakai formulir.', error: true);
      return;
    }
    final body = <String, dynamic>{
      'description': _formMode ? '' : _text.text.trim(),
      'input_mode': _formMode ? 'form' : 'text',
      'lat': _location!.latitude,
      'lng': _location!.longitude,
      'address_text': _address.text.trim().isEmpty ? null : _address.text.trim(),
      'is_manual_location': _manualLocation,
      'contact_phone': _contact.text.trim().isEmpty ? null : _contact.text.trim(),
      'photo_urls': _photos,
      if (_formMode) 'structured': _structuredBody(),
    };
    final res = await Api.instance.post('/reports', body) as Json;
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ExtractionConfirmScreen(data: res)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Laporkan kejadian')),
      floatingActionButton: AgencyFab(lat: _location?.latitude, lng: _location?.longitude),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, icon: Icon(Icons.chat_bubble_outline_rounded), label: Text('Ceritakan')),
              ButtonSegment(value: true, icon: Icon(Icons.checklist_rounded), label: Text('Isi formulir')),
            ],
            selected: {_formMode},
            onSelectionChanged: (s) => setState(() => _formMode = s.first),
          ),
          const SizedBox(height: 16),
          if (!_formMode) ..._textMode() else ..._structuredMode(),
          const SizedBox(height: 22),
          const SectionHeader('Lokasi kejadian', subtitle: 'Terpisah dari cerita: otomatis dari GPS atau pilih di peta.'),
          _locationCard(),
          const SizedBox(height: 10),
          TextField(
            controller: _address,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Alamat / patokan (opsional)',
              prefixIcon: Icon(Icons.signpost_outlined),
            ),
          ),
          const SizedBox(height: 22),
          const SectionHeader('Foto kejadian', subtitle: 'Opsional, maksimal 3 foto.'),
          _photoRow(),
          const SizedBox(height: 22),
          TextField(
            controller: _contact,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Nomor kontak (opsional)',
              helperText: 'Kosongkan untuk memakai nomor akun. Nomor selalu ditampilkan tersamar.',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
          const SizedBox(height: 26),
          BusyButton(label: 'Kirim laporan', icon: Icons.send_rounded, onPressed: _submit),
          const SizedBox(height: 10),
          const Text(
            'AI akan merangkum laporan Anda. Anda akan memeriksa hasilnya sebelum relawan dihubungi.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.inkMuted, fontSize: 13.5),
          ),
        ],
      ),
    );
  }

  List<Widget> _textMode() => [
        TextField(
          controller: _text,
          minLines: 5,
          maxLines: 10,
          autofocus: false,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(fontSize: 17),
          decoration: const InputDecoration(
            hintText: 'Contoh: Kebakaran rumah di Gang Mawar RT 05, api menjalar ke rumah sebelah. '
                'Ada lansia terjebak. Gangnya sempit, mobil damkar susah masuk.',
            hintMaxLines: 5,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.infoSoft, borderRadius: BorderRadius.circular(12)),
          child: const Row(children: [
            Icon(Icons.mic_rounded, color: AppColors.info),
            SizedBox(width: 10),
            Expanded(
              child: Text('Sulit mengetik? Tekan ikon mikrofon di keyboard untuk dikte suara.',
                  style: TextStyle(color: AppColors.info, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ];

  List<Widget> _structuredMode() => [
        DropdownButtonFormField<String>(
          initialValue: _incident,
          decoration: const InputDecoration(labelText: 'Jenis kejadian'),
          items: const [
            DropdownMenuItem(value: 'kebakaran permukiman', child: Text('Kebakaran permukiman')),
            DropdownMenuItem(value: 'banjir', child: Text('Banjir')),
            DropdownMenuItem(value: 'tanah longsor', child: Text('Tanah longsor')),
            DropdownMenuItem(value: 'gempa bumi', child: Text('Gempa bumi')),
          ],
          onChanged: (v) => setState(() => _incident = v ?? _incident),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _formLocation,
          decoration: const InputDecoration(labelText: 'Lokasi disebutkan (jalan, gang, RT/RW)'),
        ),
        const SizedBox(height: 12),
        TextField(controller: _formAccess, decoration: const InputDecoration(labelText: 'Kondisi akses')),
        const SizedBox(height: 12),
        TextField(
          controller: _formNeeds,
          decoration: const InputDecoration(labelText: 'Bantuan yang dibutuhkan', hintText: 'mis. evakuasi lansia, P3K'),
        ),
      ];

  Widget _locationCard() {
    final loc = _location;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(loc == null ? Icons.location_searching_rounded : Icons.location_on_rounded,
                color: loc == null ? AppColors.inkMuted : AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: _locating
                  ? const Text('Mencari lokasi GPS...')
                  : Text(
                      loc == null
                          ? 'Lokasi belum ditentukan'
                          : '${_manualLocation ? 'Dipilih di peta' : 'Lokasi saat ini (GPS)'}\n'
                              '${loc.latitude.toStringAsFixed(5)}, ${loc.longitude.toStringAsFixed(5)}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _locating ? null : _useGps,
                icon: const Icon(Icons.my_location_rounded),
                label: const Text('Lokasi saat ini'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickOnMap,
                icon: const Icon(Icons.map_outlined),
                label: const Text('Pilih di peta'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _photoRow() {
    return Wrap(spacing: 10, runSpacing: 10, children: [
      for (final url in _photos)
        Stack(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(Api.instance.resolve(url), width: 96, height: 96, fit: BoxFit.cover),
          ),
          Positioned(
            right: 2,
            top: 2,
            child: IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: Colors.black54, minimumSize: const Size(30, 30)),
              iconSize: 16,
              onPressed: () => setState(() => _photos.remove(url)),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ]),
      if (_uploading)
        const SizedBox(width: 96, height: 96, child: Center(child: CircularProgressIndicator())),
      if (_photos.length < 3 && !_uploading) ...[
        _PhotoButton(icon: Icons.photo_camera_outlined, label: 'Kamera', onTap: () => _addPhoto(ImageSource.camera)),
        _PhotoButton(icon: Icons.photo_library_outlined, label: 'Galeri', onTap: () => _addPhoto(ImageSource.gallery)),
      ],
    ]);
  }
}

class _PhotoButton extends StatelessWidget {
  const _PhotoButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line, width: 1.5),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: AppColors.ink),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ]),
      ),
    );
  }
}
