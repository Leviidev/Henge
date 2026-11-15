import importlib.util
from pathlib import Path
module_path = Path(__file__).resolve().parents[1] / 'tools/build_pipeline_bundle.py'
spec = importlib.util.spec_from_file_location('pipeline_bundle', module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
plan = module.configuration('/tmp/screen.metallib')
pipes = plan['pipeline_descriptors']['render_pipeline_descriptors']
assert len(pipes) == 3
assert all(p['raster_sample_count'] == 1 and p['color_attachments'][0]['pixel_format'] == 'BGRA8Unorm' for p in pipes)
assert [p['fragment_function_descriptor'] for p in pipes] == ['fnd:screen_plain', 'fnd:screen_linear', 'fnd:screen_cursor']
assert [p['color_attachments'][0]['blending_state'] for p in pipes] == ['Disabled', 'Disabled', 'Enabled']
assert pipes[2]['color_attachments'][0]['destination_rgb_blend_factor'] == 'OneMinusSourceAlpha'
assert len(plan['function_descriptors']['library_function_descriptors']) == 4
print('PASS offline pipeline plan: exact plain/half-float/cursor shaders and premultiplied blending')
