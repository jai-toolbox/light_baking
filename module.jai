/*

I can't remember if we temporary_storage'd this thing up yet, but we should. I don't think we did.

*/


#import "GL";
#import "Hash_Table";
#import "Basic";
#import "Math";
#import "stb_image_write";

#import "tbx/texture_packing";
#import "tbx/geometry";
#import "tbx/model_loading";

point_in_triangle_2d :: (p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool, float, float, float {
    v0 := c - a;
    v1 := b - a;
    v2 := p - a;

    dot00 := dot(v0, v0);
    dot01 := dot(v0, v1);
    dot02 := dot(v0, v2);
    dot11 := dot(v1, v1);
    dot12 := dot(v1, v2);

    inv_denom := 1.0 / (dot00 * dot11 - dot01 * dot01);
    u := (dot11 * dot02 - dot01 * dot12) * inv_denom;
    v := (dot00 * dot12 - dot01 * dot02) * inv_denom;
    w := 1.0 - u - v;

    inside := (u >= 0.0) && (v >= 0.0) && (w >= 0.0);

    return inside, u, v, w;
}

PIXELS_PER_UNIT  :: 30;
MAX_BOUNCES      :: 3;
SHADOW_BIAS      :: 0.001;
AO_SAMPLES       :: 64;
AO_RADIUS        :: 2.0;
BOUNCE_SAMPLES   :: 128;

Lightmap_Texel :: struct {
    direct_light:     Vector3;
    indirect_light:   Vector3;
    ambient_occlusion: float;

    world_position:   Vector3;
    world_normal:     Vector3;
    barycentrics:     Vector3;

    is_valid:         bool;
    tile_index:       s32;
}


// in the future we would need a an array of these when we run out of space.
Lightmap_Atlas :: struct {
    width:   int;
    height:  int;
    texels:  [] Lightmap_Texel;

    output_rgb: [] Vector3;
    output_rgba: [] Vector4;
}

make_lightmap_atlas :: (width: int, height: int) -> Lightmap_Atlas {
    atlas: Lightmap_Atlas;
    atlas.width  = width;
    atlas.height = height;

    count := width * height;
    atlas.texels     = NewArray(count, Lightmap_Texel);
    atlas.output_rgb = NewArray(count, Vector3);
    atlas.output_rgba = NewArray(count, Vector4);

    for i : 0..count-1 {
        atlas.texels[i].tile_index        = -1;
        atlas.texels[i].ambient_occlusion = 1.0;
    }

    return atlas;
}

free_lightmap_atlas :: (atlas: *Lightmap_Atlas) {
    array_free(atlas.texels);
    array_free(atlas.output_rgb);
    array_free(atlas.output_rgba);
}

atlas_index :: inline (atlas: *Lightmap_Atlas, x: int, y: int) -> int {
    return y * atlas.width + x;
}

// todo maybe use the Type_Info method of polymorphism here to clean up

Light_Type :: enum {
    DIRECTIONAL;
    POINT;
    SPOT;
    AREA;
}

Light :: struct {
    type:        Light_Type;
    color:       Vector3;
    intensity:   float;

    direction:   Vector3;

    position:    Vector3;
    radius:      float;

    inner_angle: float;
    outer_angle: float;

    casts_shadows: bool;
}

make_directional_light :: (direction: Vector3, color: Vector3, intensity: float, shadows: bool = true) -> Light {
    light: Light;
    light.type          = .DIRECTIONAL;
    light.direction     = normalize(direction);
    light.color         = color;
    light.intensity     = intensity;
    light.casts_shadows = shadows;
    return light;
}

make_point_light :: (position: Vector3, color: Vector3, intensity: float, radius: float = 50.0, shadows: bool = true) -> Light {
    light: Light;
    light.type          = .POINT;
    light.position      = position;
    light.color         = color;
    light.intensity     = intensity;
    light.radius        = radius;
    light.casts_shadows = shadows;
    return light;
}

make_spot_light :: (position: Vector3, direction: Vector3, color: Vector3, intensity: float, inner_angle: float, outer_angle: float, radius: float = 50.0, shadows: bool = true) -> Light {
    light: Light;
    light.type          = .SPOT;
    light.position      = position;
    light.direction     = normalize(direction);
    light.color         = color;
    light.intensity     = intensity;
    light.inner_angle   = inner_angle;
    light.outer_angle   = outer_angle;
    light.radius        = radius;
    light.casts_shadows = shadows;
    return light;
}

Ray :: struct {
    origin:    Vector3;
    direction: Vector3;
}

Ray_Hit :: struct {
    hit:       bool;
    t:         float;
    position:  Vector3;
    normal:    Vector3;
}

Bake_Config :: struct {
    do_direct_lighting:    bool = true;
    do_ambient_occlusion:  bool = false;
    do_indirect_lighting:  bool = false;
    do_dilation:           bool = true;

    ao_samples:            int  = 16;
    bounce_samples:        int  = 32;
    max_bounces:           int  = 1;

    ambient_color:         Vector3 = .{0.02, 0.02, 0.02};
}

Bake_Scene :: struct {
    gltf_data:   *Gltf_Data;
    meshes:      [..] Indexed_Mesh;
    lights:      [..] Light;
    atlas:       Lightmap_Atlas;
    packer:      Split_Packer;
    tiles:       [] Triangle_Lightmap_Tile;

    scene_tris:  [..] Scene_Triangle;

    tri_to_tile: [] int;
}

Scene_Triangle :: struct {
    p0, p1, p2:  Vector3;
    normal:       Vector3;
}


Triangle_Lightmap_Tile :: struct {

    // triangle indices into the source mesh, allows us to take a light map tile and go back to world space.
    mesh_index:       int;

    tri_index_0:      u32;
    tri_index_1:      u32;
    tri_index_2:      u32;

    block:            Block_To_Pack;

    p0:               Vector3;
    tangent:          Vector3;
    bitangent:        Vector3;
    normal:           Vector3;

    uv0:              Vector2;
    uv1:              Vector2;
    uv2:              Vector2;

    world_min:        Vector2;
    world_max:        Vector2;

    original_index:   int;
}

convert_gltf_to_indexed_meshes :: (gltf: *Gltf_Data) -> [..] Indexed_Mesh {

    meshes: [..] Indexed_Mesh;

    for *gltf_mesh : gltf.all_meshes {

        for *prim : gltf_mesh.primitives {
            if prim.position_accessor < 0 continue;
            if prim.mode != .TRIANGLES continue;

            mesh: Indexed_Mesh;

            positions := read_accessor_as_vector3_array(gltf, prim.position_accessor);
            for positions array_add(*mesh.positions, it);

            if prim.normal_accessor >= 0 {
                normals := read_accessor_as_vector3_array(gltf, prim.normal_accessor);
                for normals array_add(*mesh.normals, it);
            } else {
                for 0..positions.count-1 array_add(*mesh.normals, .{0, 1, 0});
            }

            tc0_accessor := get_texcoord_accessor(prim, 0);
            if tc0_accessor >= 0 {
                texcoords := read_accessor_as_vector2_array(gltf, tc0_accessor);
                for texcoords array_add(*mesh.texture_coordinates, it);
            } else {
                for 0..positions.count-1 array_add(*mesh.texture_coordinates, .{0, 0});
            }

            for 0..positions.count-1 {
                array_add(*mesh.rgb_colors, Vector3.{1, 1, 1});
            }

            if prim.indices_accessor >= 0 {
                indices := read_accessor_as_index_array(gltf, prim.indices_accessor);
                for indices array_add(*mesh.indices, it);
            } else {
                for i: 0..cast(u32)(positions.count - 1) {
                    array_add(*mesh.indices, i);
                }
            }

            array_add(*meshes, mesh);
        }
    }

    return meshes;
}

init_bake_scene :: (gltf_data: *Gltf_Data, atlas_width: int, atlas_height: int) -> Bake_Scene {
    scene: Bake_Scene;
    scene.gltf_data = gltf_data;
    scene.meshes    = convert_gltf_to_indexed_meshes(gltf_data);
    scene.atlas     = make_lightmap_atlas(atlas_width, atlas_height);

    scene.packer, scene.tiles = generate_lightmap_atlas(*scene.meshes, atlas_width, atlas_height);

    // build reverse mapping: original_tri_index -> sorted tile index
    scene.tri_to_tile = NewArray(scene.tiles.count, int);
    for tile_idx : 0..scene.tiles.count - 1 {
        scene.tri_to_tile[scene.tiles[tile_idx].original_index] = tile_idx;
    }

    build_scene_triangles(*scene);

    return scene;
}

build_scene_triangles :: (scene: *Bake_Scene) {
    for *mesh : scene.meshes {
        tri_count := mesh.indices.count / 3;
        for i : 0..tri_count - 1 {
            i0 := mesh.indices[i * 3 + 0];
            i1 := mesh.indices[i * 3 + 1];
            i2 := mesh.indices[i * 3 + 2];

            p0 := mesh.positions[i0];
            p1 := mesh.positions[i1];
            p2 := mesh.positions[i2];

            tri: Scene_Triangle;
            tri.p0     = p0;
            tri.p1     = p1;
            tri.p2     = p2;
            tri.normal = normalize(cross(p1 - p0, p2 - p0));
            array_add(*scene.scene_tris, tri);
        }
    }
}

free_bake_scene :: (scene: *Bake_Scene) {
    free_lightmap_atlas(*scene.atlas);
    array_free(scene.lights);
    array_free(scene.scene_tris);
    array_free(scene.meshes);
    array_free(scene.tri_to_tile);
}

EPSILON :: 0.000001;

// moller-trumbore
ray_triangle_intersect :: (ray: Ray, tri: *Scene_Triangle, max_t: float = FLOAT32_MAX) -> bool, float {
    edge1 := tri.p1 - tri.p0;
    edge2 := tri.p2 - tri.p0;

    h := cross(ray.direction, edge2);
    a := dot(edge1, h);

    if a > -EPSILON && a < EPSILON  return false, 0;

    f := 1.0 / a;
    s := ray.origin - tri.p0;
    u := f * dot(s, h);
    if u < 0.0 || u > 1.0  return false, 0;

    q := cross(s, edge1);
    v := f * dot(ray.direction, q);
    if v < 0.0 || u + v > 1.0  return false, 0;

    t := f * dot(edge2, q);
    if t > EPSILON && t < max_t  return true, t;

    return false, 0;
}

trace_ray :: (scene: *Bake_Scene, ray: Ray, max_t: float = FLOAT32_MAX) -> Ray_Hit {
    result: Ray_Hit;
    result.t = max_t;

    for *tri : scene.scene_tris {
        hit, t := ray_triangle_intersect(ray, tri, result.t);
        if hit {
            result.hit      = true;
            result.t        = t;
            result.position = ray.origin + t * ray.direction;
            result.normal   = tri.normal;
        }
    }

    return result;
}

is_shadowed :: (scene: *Bake_Scene, origin: Vector3, light_dir: Vector3, max_dist: float = FLOAT32_MAX) -> bool {
    shadow_ray: Ray;
    shadow_ray.origin    = origin + light_dir * SHADOW_BIAS;
    shadow_ray.direction = light_dir;

    hit := trace_ray(scene, shadow_ray, max_dist);
    return hit.hit;
}

pass_rasterize_geometry :: (scene: *Bake_Scene) {
    atlas := *scene.atlas;

    for tile_idx : 0..scene.tiles.count - 1 {
        tile := *scene.tiles[tile_idx];
        placement := tile.block.packed_placement;
        if placement == null continue;

        for py : 0..tile.block.h - 1 {
            for px : 0..tile.block.w - 1 {
                u := tile.world_min.x + (cast(float)px + 0.5) / cast(float)PIXELS_PER_UNIT;
                v := tile.world_min.y + (cast(float)py + 0.5) / cast(float)PIXELS_PER_UNIT;
                p := Vector2.{u, v};

                inside, bary_u, bary_v, bary_w := point_in_triangle_2d(p, tile.uv0, tile.uv1, tile.uv2);
                if !inside continue;

                world_pos := tile.p0 + u * tile.tangent + v * tile.bitangent;

                atlas_x := placement.top_left_x + px;
                atlas_y := placement.top_left_y + py;
                idx     := atlas_index(atlas, atlas_x, atlas_y);

                texel := *atlas.texels[idx];
                texel.is_valid       = true;
                texel.tile_index     = cast(s32)tile_idx;
                texel.world_position = world_pos;
                texel.world_normal   = tile.normal;
                texel.barycentrics   = .{bary_u, bary_v, bary_w};
            }
        }
    }
}

pass_direct_lighting :: (scene: *Bake_Scene) {
    atlas := *scene.atlas;

    for i : 0..atlas.texels.count - 1 {
        texel := *atlas.texels[i];
        if !texel.is_valid continue;

        accumulated := Vector3.{0, 0, 0};

        for *light : scene.lights {
            contribution := evaluate_light(scene, texel, light);
            accumulated = accumulated + contribution;
        }

        texel.direct_light = accumulated;
    }
}

evaluate_light :: (scene: *Bake_Scene, texel: *Lightmap_Texel, light: *Light) -> Vector3 {
    if light.type == {
        case .DIRECTIONAL;
            return evaluate_directional(scene, texel, light);
        case .POINT;
            return evaluate_point(scene, texel, light);
        case .SPOT;
            return evaluate_spot(scene, texel, light);
        case;
            return .{0,0,0};
    }
}

evaluate_directional :: (scene: *Bake_Scene, texel: *Lightmap_Texel, light: *Light) -> Vector3 {
    light_dir := light.direction;
    NdotL := dot(texel.world_normal, light_dir);
    if NdotL <= 0  return .{0, 0, 0};

    if light.casts_shadows {
        if is_shadowed(scene, texel.world_position, light_dir)
            return .{0, 0, 0};
    }

    return light.color * light.intensity * NdotL;
}

evaluate_point :: (scene: *Bake_Scene, texel: *Lightmap_Texel, light: *Light) -> Vector3 {
    to_light := light.position - texel.world_position;
    dist     := length(to_light);
    if dist > light.radius  return .{0, 0, 0};

    light_dir := to_light / dist;
    NdotL     := dot(texel.world_normal, light_dir);
    if NdotL <= 0  return .{0, 0, 0};

    if light.casts_shadows {
        if is_shadowed(scene, texel.world_position, light_dir, dist)
            return .{0, 0, 0};
    }

    attenuation := 1.0 / (dist * dist + 1.0);
    falloff := saturate(1.0 - (dist / light.radius));
    falloff = falloff * falloff;

    return light.color * light.intensity * NdotL * attenuation * falloff;
}

evaluate_spot :: (scene: *Bake_Scene, texel: *Lightmap_Texel, light: *Light) -> Vector3 {
    to_light := light.position - texel.world_position;
    dist     := length(to_light);
    if dist > light.radius  return .{0, 0, 0};

    light_dir := to_light / dist;
    NdotL     := dot(texel.world_normal, light_dir);
    if NdotL <= 0  return .{0, 0, 0};

    cos_angle   := dot(-light_dir, light.direction);
    cos_inner   := cos(light.inner_angle);
    cos_outer   := cos(light.outer_angle);
    spot_factor := saturate((cos_angle - cos_outer) / (cos_inner - cos_outer));

    if spot_factor <= 0  return .{0, 0, 0};

    if light.casts_shadows {
        if is_shadowed(scene, texel.world_position, light_dir, dist)
            return .{0, 0, 0};
    }

    attenuation := 1.0 / (dist * dist + 1.0);
    falloff := saturate(1.0 - (dist / light.radius));
    falloff = falloff * falloff;

    return light.color * light.intensity * NdotL * attenuation * falloff * spot_factor;
}

pass_ambient_occlusion :: (scene: *Bake_Scene, num_samples: int = 64) {
    atlas := *scene.atlas;

    for i : 0..atlas.texels.count - 1 {
        texel := *atlas.texels[i];
        if !texel.is_valid continue;

        occluded_count := 0;

        for sample : 0..num_samples - 1 {
            dir := cosine_weighted_hemisphere_sample(texel.world_normal, sample);

            ray: Ray;
            ray.origin    = texel.world_position + texel.world_normal * SHADOW_BIAS;
            ray.direction = dir;

            hit := trace_ray(scene, ray, AO_RADIUS);
            if hit.hit  occluded_count += 1;
        }

        texel.ambient_occlusion = 1.0 - (cast(float)occluded_count / cast(float)num_samples);
    }
}

pass_indirect_lighting :: (scene: *Bake_Scene, bounce: int = 0, num_samples: int = 128) {
    atlas := *scene.atlas;

    for i : 0..atlas.texels.count - 1 {
        texel := *atlas.texels[i];
        if !texel.is_valid continue;

        accumulated := Vector3.{0, 0, 0};

        for sample : 0..num_samples - 1 {
            dir := cosine_weighted_hemisphere_sample(texel.world_normal, sample + bounce * num_samples);

            ray: Ray;
            ray.origin    = texel.world_position + texel.world_normal * SHADOW_BIAS;
            ray.direction = dir;

            hit := trace_ray(scene, ray);
            if hit.hit {
                hit_light := sample_atlas_at_world_position(scene, hit.position, hit.normal);

                NdotL := max(0.0, dot(texel.world_normal, dir));
                accumulated = accumulated + hit_light * NdotL;
            }
        }

        texel.indirect_light = texel.indirect_light + accumulated * (1.0 / cast(float)num_samples);
    }
}

sample_atlas_at_world_position :: (scene: *Bake_Scene, world_pos: Vector3, normal: Vector3) -> Vector3 {
    atlas := *scene.atlas;

    best_dist := FLOAT32_MAX;
    best_light := Vector3.{0, 0, 0};

    for i : 0..atlas.texels.count - 1 {
        texel := *atlas.texels[i];
        if !texel.is_valid continue;

        d := length_squared(texel.world_position - world_pos);
        if d < best_dist {
            best_dist  = d;
            best_light = texel.direct_light + texel.indirect_light;
        }
    }

    return best_light;
}

pass_composite :: (scene: *Bake_Scene, ambient: Vector3 = .{0.02, 0.02, 0.02}) {
    atlas := *scene.atlas;

    for i : 0..atlas.texels.count - 1 {
        texel := *atlas.texels[i];

        if !texel.is_valid {
            atlas.output_rgb[i]  = .{0, 0, 0};
            atlas.output_rgba[i] = .{0, 0, 0, 0};
            continue;
        }

        total := texel.direct_light + texel.indirect_light + ambient;
        total = total * texel.ambient_occlusion;

        atlas.output_rgb[i]  = total;
        atlas.output_rgba[i] = .{total.x, total.y, total.z, 1.0};
    }
}


pass_dilate :: (scene: *Bake_Scene, iterations: int = 4) {
    atlas := *scene.atlas;
    w := atlas.width;
    h := atlas.height;

    for iter : 0..iterations - 1 {
        for y : 0..h - 1 {
            for x : 0..w - 1 {
                idx := atlas_index(atlas, x, y);
                if atlas.output_rgba[idx].w > 0.0  continue;

                sum   := Vector3.{0, 0, 0};
                count := 0;

                for dy : -1..1 {
                    for dx : -1..1 {
                        if dx == 0 && dy == 0  continue;
                        nx := x + dx;
                        ny := y + dy;
                        if nx < 0 || nx >= w || ny < 0 || ny >= h  continue;

                        nidx := atlas_index(atlas, nx, ny);
                        if atlas.output_rgba[nidx].w > 0.0 {
                            sum   = sum + atlas.output_rgb[nidx];
                            count += 1;
                        }
                    }
                }

                if count > 0 {
                    avg := sum * (1.0 / cast(float)count);
                    atlas.output_rgb[idx]  = avg;
                    atlas.output_rgba[idx] = .{avg.x, avg.y, avg.z, 1.0};
                }
            }
        }
    }
}

cosine_weighted_hemisphere_sample :: (normal: Vector3, sample_index: int) -> Vector3 {
    u1 := radical_inverse_base2(cast(u32)(sample_index + 1));
    u2 := radical_inverse_base3(cast(u32)(sample_index + 1));

    r     := sqrt(u1);
    theta := 2.0 * PI * u2;

    x := r * cos(theta);
    y := r * sin(theta);
    z := sqrt(max(0.0, 1.0 - u1));

    t, b := build_tangent_frame(normal);

    return normalize(x * t + y * b + z * normal);
}

build_tangent_frame :: (n: Vector3) -> Vector3, Vector3 {
    if n.z < -0.9999999 {
        return .{0, -1, 0}, .{-1, 0, 0};
    }
    a := 1.0 / (1.0 + n.z);
    b := -n.x * n.y * a;
    t := Vector3.{1.0 - n.x * n.x * a, b, -n.x};
    bi := Vector3.{b, 1.0 - n.y * n.y * a, -n.y};
    return t, bi;
}

/*
 Computes the radical inverse of the bits argument in base 2 (also known as the Van der Corput sequence).

 The "radical inverse" of a non-negative integer n in base b works like this:
   - Write n in base b:                                n = d_k d_{k-1} ... d_1 d_0
   - Reflect those digits across the decimal point:    0 . d_0 d_1 ... d_{k-1} d_k
   - Return that fractional value.

 In base 2 this is equivalent to:
   1. Take the 32-bit binary representation of the bits argument
   2. Reverse all 32 bits (so the least significant becomes the becomes most significant, etc...)
   3. Treat the result as a fixed-point number in [0, 1) by multiplying by 2^-32  (i.e. "0." followed by those 32 bits in binary)

 The clever trick here is that bit-reversal is performed entirely with
 bitwise ops in O(log 32) = 5 swap passes instead of a 32-iteration loop.
 Each pass swaps a finer and finer grain of bit groups:

   Pass 1: swap the two 16-bit halves  (grain = 16 bits)
   Pass 2: swap every pair of adjacent bits  (grain = 1 bit, within each byte pair)
   Pass 3: swap every pair of adjacent 2-bit groups  (grain = 2 bits)
   Pass 4: swap every pair of adjacent 4-bit nibbles  (grain = 4 bits)
   Pass 5: swap every pair of adjacent bytes  (grain = 8 bits)

 After all 5 passes the bit order is fully reversed.

 Why is this useful?

  The sequence  radical_inverse_base2(0), radical_inverse_base2(1), ...
  fills [0,1) very uniformly (low-discrepancy). This makes it ideal for
  quasi-Monte Carlo integration, where you want sample points spread out
  as evenly as possible rather than clustered randomly.

*/

radical_inverse_base2 :: (bits: u32) -> float {
    b := bits;

    // swap the upper 16 bits with the lower 16 bits
    // Before: [b31 b30 ... b16 | b15 b14 ... b0]
    // After:  [b15 b14 ... b0  | b31 b30 ... b16]
    b = (b << 16) | (b >> 16);

    // within every 2-bit group, swap the two bits
    // mask 0x55555555 = 0101 0101 ... selects every even bit  (bit positions 0,2,4,...)
    // mask 0xAAAAAAAA = 1010 1010 ... selects every odd  bit  (bit positions 1,3,5,...)
    // shift even bits left by 1 and odd bits right by 1, then OR them together
    b = ((b & 0x55555555) << 1) | ((b & 0xAAAAAAAA) >> 1);

    // within every 4-bit group, swap the two 2-bit halves
    // mask 0x33333333 = 0011 0011 ... selects bits [1:0] of each nibble
    // mask 0xCCCCCCCC = 1100 1100 ... selects bits [3:2] of each nibble
    b = ((b & 0x33333333) << 2) | ((b & 0xCCCCCCCC) >> 2);

    // within every 8-bit byte, swap the two 4-bit nibbles 
    // mask 0x0F0F0F0F = 0000 1111 ... selects the low  nibble of each byte
    // mask 0xF0F0F0F0 = 1111 0000 ... selects the high nibble of each byte
    b = ((b & 0x0F0F0F0F) << 4) | ((b & 0xF0F0F0F0) >> 4);

    // within every 16-bit word, swap the two bytes
    // mask 0x00FF00FF selects the low  byte of each 16-bit half
    // mask 0xFF00FF00 selects the high byte of each 16-bit half
    b = ((b & 0x00FF00FF) << 8) | ((b & 0xFF00FF00) >> 8);

    // b now holds the bit-reversal of the original bits value.

    // map the reversed 32-bit integer into the range [0, 1)
    // INV_2_32 = 1 / 2^32 ≈ 2.3283064e-10
    // multiplying by this is the same as placing a binary point before all 32 bits,
    // turning 0xFFFFFFFF into 0.9999999997... and 0x00000001 into the smallest
    // representable step (~2.33e-10).
    INV_2_32 : float : 2.3283064e-10;
    return cast(float)b * INV_2_32;
}

/*
 Computes the radical inverse of `index` in base 3.

 This is the straightforward digit-extraction approach (no bit tricks needed since base 3 doesn't map neatly onto binary hardware ops).

 Algorithm:
   Repeatedly pull off the least-significant base-3 digit (index % 3),
   weight it by the current power of (1/3), accumulate, then shift the
   number right one base-3 place (index /= 3).

 Example for index = 5:
   5 in base 3 is "12"  (1*3 + 2)
   Radical inverse  = 0.21 in base 3
                    = 2*(1/3) + 1*(1/9)
                    = 0.666... + 0.111... = 0.777...

 Used alongside radical_inverse_base2 to form the 2D Halton sequence a low-discrepancy point set popular in rendering and numerical integration.
 
 */

radical_inverse_base3 :: (index: u32) -> float {
    n := index;
    inv_base: float = 1.0 / 3.0;   // 1/3
    inv_base_n: float = inv_base;   // tracks (1/3)^digit_position, starting at (1/3)^1
    result: float = 0.0;

    while n > 0 {
        digit := n % 3;                          // least-significant base-3 digit
        result += cast(float)digit * inv_base_n; // weight it by its place value
        inv_base_n *= inv_base;                  // move one more place to the right: (1/3)^(i+1)
        n /= 3;                                  // shift off the digit we just processed
    }

    return result;
}


bake_lightmap :: (scene: *Bake_Scene, config: Bake_Config = .{}) {
    print("pass 0: rasterizing geometry...\n");
    pass_rasterize_geometry(scene);

    if config.do_direct_lighting {
        print("pass 1: direct lighting...\n");
        pass_direct_lighting(scene);
    }

    if config.do_ambient_occlusion {
        print("pass 2: ambient occlusion (% samples)...\n", config.ao_samples);
        pass_ambient_occlusion(scene, config.ao_samples);
    }

    if config.do_indirect_lighting {
        for bounce : 0..config.max_bounces - 1 {
            print("pass 3.%: indirect bounce % (% samples)...\n", bounce, bounce, config.bounce_samples);
            pass_indirect_lighting(scene, bounce, config.bounce_samples);
        }
    }

    print("pass 4: compositing...\n");
    pass_composite(scene, config.ambient_color);

    if config.do_dilation {
        print("pass 5: dilation...\n");
        pass_dilate(scene);
    }

    print("bake complete\n");
}

generate_lightmap_atlas :: (meshes: *[..] Indexed_Mesh, atlas_width: int, atlas_height: int) -> Split_Packer, [] Triangle_Lightmap_Tile {
    tiles: [..] Triangle_Lightmap_Tile;

    for mesh_idx : 0..meshes.count - 1 {
        mesh := *meshes.*[mesh_idx];
        tri_count := mesh.indices.count / 3;

        for tri_idx : 0..tri_count - 1 {
            i0 := mesh.indices[tri_idx * 3 + 0];
            i1 := mesh.indices[tri_idx * 3 + 1];
            i2 := mesh.indices[tri_idx * 3 + 2];

            p0 := mesh.positions[i0];
            p1 := mesh.positions[i1];
            p2 := mesh.positions[i2];

            edge0 := p1 - p0;
            edge1 := p2 - p0;

            tangent   := normalize(edge0);
            normal    := normalize(cross(edge0, edge1));
            bitangent := cross(normal, tangent);

            uv0 := Vector2.{0, 0};
            uv1 := Vector2.{dot(edge0, tangent), dot(edge0, bitangent)};
            uv2 := Vector2.{dot(edge1, tangent), dot(edge1, bitangent)};

            min_u :=  FLOAT32_MAX;
            min_v :=  FLOAT32_MAX;
            max_u := -FLOAT32_MAX;
            max_v := -FLOAT32_MAX;

            for vi : 0..2 {
                idx := mesh.indices[tri_idx * 3 + vi];
                p   := mesh.positions[idx];
                rel := p - p0;

                u := dot(rel, tangent);
                v := dot(rel, bitangent);

                if u < min_u then min_u = u;
                if u > max_u then max_u = u;
                if v < min_v then min_v = v;
                if v > max_v then max_v = v;
            }

            world_w := max_u - min_u;
            world_h := max_v - min_v;

            pixel_w := max(1, cast(int)(world_w * PIXELS_PER_UNIT + 0.5));
            pixel_h := max(1, cast(int)(world_h * PIXELS_PER_UNIT + 0.5));

            tile: Triangle_Lightmap_Tile;
            tile.mesh_index  = mesh_idx;
            tile.tri_index_0 = i0;
            tile.tri_index_1 = i1;
            tile.tri_index_2 = i2;
            tile.block       = make_block_to_pack(pixel_w, pixel_h);
            tile.p0          = p0;
            tile.tangent     = tangent;
            tile.bitangent   = bitangent;
            tile.normal      = normal;
            tile.uv0         = uv0;
            tile.uv1         = uv1;
            tile.uv2         = uv2;
            tile.world_min   = .{min_u, min_v};
            tile.world_max   = .{max_u, max_v};

            array_add(*tiles, tile);
        }
    }

    // assign original indices before sorting
    for tile_idx : 0..tiles.count - 1 {
        tiles[tile_idx].original_index = tile_idx;
    }

    // sort tiles by height descending (insertion sort)
    for i : 1..tiles.count - 1 {
        j := i;
        while j > 0 && tiles[j].block.h > tiles[j-1].block.h {
            tmp        := tiles[j];
            tiles[j]   = tiles[j-1];
            tiles[j-1] = tmp;
            j -= 1;
        }
    }

    packer := make_split_packer(atlas_width, atlas_height);

    for *tile : tiles {
        fit(*packer, *tile.block);
    }

    return packer, tiles;
}

write_lightmap_png :: (filename: string, atlas: *Lightmap_Atlas) {
    w := atlas.width;
    h := atlas.height;
    count := w * h;

    pixels := NewArray(count * 4, u8);
    defer array_free(pixels);

    for i : 0..count - 1 {
        color := atlas.output_rgba[i];

        r := color.x / (color.x + 1.0);
        g := color.y / (color.y + 1.0);
        b := color.z / (color.z + 1.0);
        a := color.w;

        r = pow(saturate(r), 1.0 / 2.2);
        g = pow(saturate(g), 1.0 / 2.2);
        b = pow(saturate(b), 1.0 / 2.2);

        pixels[i * 4 + 0] = cast(u8)(r * 255.0 + 0.5);
        pixels[i * 4 + 1] = cast(u8)(g * 255.0 + 0.5);
        pixels[i * 4 + 2] = cast(u8)(b * 255.0 + 0.5);
        pixels[i * 4 + 3] = cast(u8)(saturate(a) * 255.0 + 0.5);
    }

    c_filename := to_c_string(filename);
    defer free(c_filename);

    stride := cast(s32)(w * 4);

    result := stbi_write_png(
        c_filename,
        cast(s32)w,
        cast(s32)h,
        4,
        pixels.data,
        stride
    );

    if result == 0 {
        print("ERROR: Failed to write lightmap to '%'\n", filename);
    } else {
        print("Wrote lightmap: '%' (%x%, % bytes)\n", filename, w, h, count * 4);
    }
}

write_lightmap_hdr :: (filename: string, atlas: *Lightmap_Atlas) {
    w := atlas.width;
    h := atlas.height;
    count := w * h;

    pixels := NewArray(count * 3, float);
    defer array_free(pixels);

    for i : 0..count - 1 {
        color := atlas.output_rgb[i];
        pixels[i * 3 + 0] = color.x;
        pixels[i * 3 + 1] = color.y;
        pixels[i * 3 + 2] = color.z;
    }

    c_filename := to_c_string(filename);
    defer free(c_filename);

    result := stbi_write_hdr(
        c_filename,
        cast(s32)w,
        cast(s32)h,
        3,
        pixels.data
    );

    if result == 0 {
        print("ERROR: Failed to write HDR lightmap to '%'\n", filename);
    } else {
        print("Wrote HDR lightmap: '%' (%x%)\n", filename, w, h);
    }
}

write_lightmap_debug_direct :: (filename: string, atlas: *Lightmap_Atlas) {
    write_lightmap_channel_png(filename, atlas, (texel: *Lightmap_Texel) -> Vector3 {
        return texel.direct_light;
    });
}

write_lightmap_debug_indirect :: (filename: string, atlas: *Lightmap_Atlas) {
    write_lightmap_channel_png(filename, atlas, (texel: *Lightmap_Texel) -> Vector3 {
        return texel.indirect_light;
    });
}

write_lightmap_debug_ao :: (filename: string, atlas: *Lightmap_Atlas) {
    write_lightmap_channel_png(filename, atlas, (texel: *Lightmap_Texel) -> Vector3 {
        ao := texel.ambient_occlusion;
        return .{ao, ao, ao};
    });
}

write_lightmap_debug_normals :: (filename: string, atlas: *Lightmap_Atlas) {
    write_lightmap_channel_png(filename, atlas, (texel: *Lightmap_Texel) -> Vector3 {
        n := texel.world_normal;
        return .{n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5};
    });
}

write_lightmap_channel_png :: (filename: string, atlas: *Lightmap_Atlas, extract: (texel: *Lightmap_Texel) -> Vector3) {
    w := atlas.width;
    h := atlas.height;
    count := w * h;

    pixels := NewArray(count * 4, u8);
    defer array_free(pixels);

    for i : 0..count - 1 {
        texel := *atlas.texels[i];

        if !texel.is_valid {
            pixels[i * 4 + 0] = 0;
            pixels[i * 4 + 1] = 0;
            pixels[i * 4 + 2] = 0;
            pixels[i * 4 + 3] = 0;
            continue;
        }

        color := extract(texel);

        r := pow(saturate(color.x / (color.x + 1.0)), 1.0 / 2.2);
        g := pow(saturate(color.y / (color.y + 1.0)), 1.0 / 2.2);
        b := pow(saturate(color.z / (color.z + 1.0)), 1.0 / 2.2);

        pixels[i * 4 + 0] = cast(u8)(r * 255.0 + 0.5);
        pixels[i * 4 + 1] = cast(u8)(g * 255.0 + 0.5);
        pixels[i * 4 + 2] = cast(u8)(b * 255.0 + 0.5);
        pixels[i * 4 + 3] = 255;
    }

    c_filename := to_c_string(filename);
    defer free(c_filename);

    stride := cast(s32)(w * 4);
    result := stbi_write_png(c_filename, cast(s32)w, cast(s32)h, 4, pixels.data, stride);

    if result == 0 {
        print("ERROR: Failed to write debug lightmap '%'\n", filename);
    } else {
        print("Wrote debug lightmap: '%'\n", filename);
    }
}

