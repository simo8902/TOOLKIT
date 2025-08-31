# PRODBYSIMO
# 08/31/2025 
import struct, argparse
import math
import os, sys
    
def quaternion_from_matrix(m):
    if len(m) == 9:
        m11, m12, m13 = m[0], m[1], m[2]
        m21, m22, m23 = m[3], m[4], m[5]
        m31, m32, m33 = m[6], m[7], m[8]
    elif len(m) == 12:
        m11, m12, m13 = m[0], m[1], m[2]
        m21, m22, m23 = m[4], m[5], m[6]
        m31, m32, m33 = m[8], m[9], m[10]
    elif len(m) == 16:
        m11, m12, m13 = m[0], m[1], m[2]
        m21, m22, m23 = m[4], m[5], m[6]
        m31, m32, m33 = m[8], m[9], m[10]
    else:
        return [0, 0, 0, 1]
    
    trace = m11 + m22 + m33
    
    if trace > 0:
        s = 0.5 / math.sqrt(trace + 1.0)
        w = 0.25 / s
        x = (m32 - m23) * s
        y = (m13 - m31) * s
        z = (m21 - m12) * s
    elif m11 > m22 and m11 > m33:
        s = 2.0 * math.sqrt(1.0 + m11 - m22 - m33)
        w = (m32 - m23) / s
        x = 0.25 * s
        y = (m12 + m21) / s
        z = (m13 + m31) / s
    elif m22 > m33:
        s = 2.0 * math.sqrt(1.0 + m22 - m11 - m33)
        w = (m13 - m31) / s
        x = (m12 + m21) / s
        y = 0.25 * s
        z = (m23 + m32) / s
    else:
        s = 2.0 * math.sqrt(1.0 + m33 - m11 - m22)
        w = (m21 - m12) / s
        x = (m13 + m31) / s
        y = (m23 + m32) / s
        z = 0.25 * s
    
    return [x, y, z, w]

def validate_transform(pos, scale, quat):
    try:
        for p in pos:
            if math.isnan(p) or math.isinf(p) or abs(p) > 1e6:
                return False
        for s in scale:
            if math.isnan(s) or math.isinf(s) or s <= 0 or s > 1000:
                return False
        for q in quat:
            if math.isnan(q) or math.isinf(q):
                return False
        quat_len = math.sqrt(sum(q*q for q in quat))
        if abs(quat_len - 1.0) > 0.1:
            return False
        return True
    except:
        return False

def try_parse_4x4_matrix(data, offset):
    try:
        values = struct.unpack_from('<16f', data, offset)
        pos = [values[12], values[13], values[14]]
        scale = [
            math.sqrt(values[0]**2 + values[4]**2 + values[8]**2),
            math.sqrt(values[1]**2 + values[5]**2 + values[9]**2),
            math.sqrt(values[2]**2 + values[6]**2 + values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 64
    except:
        return None

def try_parse_3x4_matrix(data, offset):
    try:
        values = struct.unpack_from('<12f', data, offset)
        pos = [values[9], values[10], values[11]]
        scale = [
            math.sqrt(values[0]**2 + values[3]**2 + values[6]**2),
            math.sqrt(values[1]**2 + values[4]**2 + values[7]**2),
            math.sqrt(values[2]**2 + values[5]**2 + values[8]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(values[i*3+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 48
    except:
        return None

def try_parse_pos_quat_scale(data, offset):
    try:
        values = struct.unpack_from('<10f', data, offset)
        pos = list(values[0:3])
        quat = list(values[3:7])
        scale = list(values[7:10])
        return pos, scale, quat, 40
    except:
        return None

def try_parse_quat_pos_scale(data, offset):
    try:
        values = struct.unpack_from('<10f', data, offset)
        quat = list(values[0:4])
        pos = list(values[4:7])
        scale = list(values[7:10])
        return pos, scale, quat, 40
    except:
        return None

def try_parse_scale_pos_quat(data, offset):
    try:
        values = struct.unpack_from('<10f', data, offset)
        scale = list(values[0:3])
        pos = list(values[3:6])
        quat = list(values[6:10])
        return pos, scale, quat, 40
    except:
        return None

def try_parse_1int_16f(data, offset):
    try:
        values = struct.unpack_from('<I16f', data, offset)
        matrix_values = values[1:]
        pos = [matrix_values[12], matrix_values[13], matrix_values[14]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[4]**2 + matrix_values[8]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[5]**2 + matrix_values[9]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[6]**2 + matrix_values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 68
    except:
        return None

def try_parse_2int_16f(data, offset):
    try:
        values = struct.unpack_from('<II16f', data, offset)
        matrix_values = values[2:]
        pos = [matrix_values[12], matrix_values[13], matrix_values[14]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[4]**2 + matrix_values[8]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[5]**2 + matrix_values[9]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[6]**2 + matrix_values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 72
    except:
        return None

def try_parse_1int_12f(data, offset):
    try:
        values = struct.unpack_from('<I12f', data, offset)
        matrix_values = values[1:]
        pos = [matrix_values[9], matrix_values[10], matrix_values[11]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[3]**2 + matrix_values[6]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[4]**2 + matrix_values[7]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[5]**2 + matrix_values[8]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*3+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 52
    except:
        return None

def try_parse_2int_12f(data, offset):
    try:
        values = struct.unpack_from('<II12f', data, offset)
        matrix_values = values[2:]
        pos = [matrix_values[9], matrix_values[10], matrix_values[11]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[3]**2 + matrix_values[6]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[4]**2 + matrix_values[7]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[5]**2 + matrix_values[8]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*3+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 56
    except:
        return None

def try_parse_4byte_pad_16f(data, offset):
    try:
        values = struct.unpack_from('<I16f', data, offset)
        matrix_values = values[1:]
        pos = [matrix_values[12], matrix_values[13], matrix_values[14]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[4]**2 + matrix_values[8]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[5]**2 + matrix_values[9]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[6]**2 + matrix_values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 68
    except:
        return None

def try_parse_8byte_pad_12f(data, offset):
    try:
        values = struct.unpack_from('<II12f', data, offset)
        matrix_values = values[2:]
        pos = [matrix_values[9], matrix_values[10], matrix_values[11]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[3]**2 + matrix_values[6]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[4]**2 + matrix_values[7]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[5]**2 + matrix_values[8]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*3+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 56
    except:
        return None

def try_parse_1short_16f(data, offset):
    try:
        values = struct.unpack_from('<H16f', data, offset)
        matrix_values = values[1:]
        pos = [matrix_values[12], matrix_values[13], matrix_values[14]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[4]**2 + matrix_values[8]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[5]**2 + matrix_values[9]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[6]**2 + matrix_values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 66
    except:
        return None

def try_parse_2short_16f(data, offset):
    try:
        values = struct.unpack_from('<HH16f', data, offset)
        matrix_values = values[2:]
        pos = [matrix_values[12], matrix_values[13], matrix_values[14]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[4]**2 + matrix_values[8]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[5]**2 + matrix_values[9]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[6]**2 + matrix_values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 68
    except:
        return None

def try_parse_1byte_16f(data, offset):
    try:
        values = struct.unpack_from('<B16f', data, offset)
        matrix_values = values[1:]
        pos = [matrix_values[12], matrix_values[13], matrix_values[14]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[4]**2 + matrix_values[8]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[5]**2 + matrix_values[9]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[6]**2 + matrix_values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 65
    except:
        return None

def try_parse_4byte_16f(data, offset):
    try:
        values = struct.unpack_from('<BBBB16f', data, offset)
        matrix_values = values[4:]
        pos = [matrix_values[12], matrix_values[13], matrix_values[14]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[4]**2 + matrix_values[8]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[5]**2 + matrix_values[9]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[6]**2 + matrix_values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 68
    except:
        return None

def try_parse_transposed_4x4(data, offset):
    try:
        values = struct.unpack_from('<16f', data, offset)
        pos = [values[3], values[7], values[11]]
        scale = [
            math.sqrt(values[0]**2 + values[1]**2 + values[2]**2),
            math.sqrt(values[4]**2 + values[5]**2 + values[6]**2),
            math.sqrt(values[8]**2 + values[9]**2 + values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(values[j*4+i] / scale[i] if scale[i] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 64
    except:
        return None

def try_parse_transposed_3x4(data, offset):
    try:
        values = struct.unpack_from('<12f', data, offset)
        pos = [values[3], values[7], values[11]]
        scale = [
            math.sqrt(values[0]**2 + values[1]**2 + values[2]**2),
            math.sqrt(values[4]**2 + values[5]**2 + values[6]**2),
            math.sqrt(values[8]**2 + values[9]**2 + values[10]**2)
        ]
        rot_matrix = []
        for col in range(3):
            for row in range(3):
                idx = col * 4 + row
                rot_matrix.append(values[idx] / scale[row] if scale[row] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 48
    except:
        return None

def try_parse_1int_10f(data, offset):
    try:
        values = struct.unpack_from('<I10f', data, offset)
        pos = list(values[1:4])
        quat = list(values[4:8])
        scale = list(values[8:11])
        return pos, scale, quat, 44
    except:
        return None

def try_parse_2int_10f(data, offset):
    try:
        values = struct.unpack_from('<II10f', data, offset)
        pos = list(values[2:5])
        quat = list(values[5:9])
        scale = list(values[9:12])
        return pos, scale, quat, 48
    except:
        return None

def try_parse_16byte_pad_16f(data, offset):
    try:
        values = struct.unpack_from('<IIII16f', data, offset)
        matrix_values = values[4:]
        pos = [matrix_values[12], matrix_values[13], matrix_values[14]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[4]**2 + matrix_values[8]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[5]**2 + matrix_values[9]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[6]**2 + matrix_values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 80
    except:
        return None

def try_parse_12byte_pad_12f(data, offset):
    try:
        values = struct.unpack_from('<III12f', data, offset)
        matrix_values = values[3:]
        pos = [matrix_values[9], matrix_values[10], matrix_values[11]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[3]**2 + matrix_values[6]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[4]**2 + matrix_values[7]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[5]**2 + matrix_values[8]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*3+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 60
    except:
        return None

def try_parse_3int_16f(data, offset):
    try:
        values = struct.unpack_from('<III16f', data, offset)
        matrix_values = values[3:]
        pos = [matrix_values[12], matrix_values[13], matrix_values[14]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[4]**2 + matrix_values[8]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[5]**2 + matrix_values[9]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[6]**2 + matrix_values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 76
    except:
        return None

def try_parse_4int_12f(data, offset):
    try:
        values = struct.unpack_from('<IIII12f', data, offset)
        matrix_values = values[4:]
        pos = [matrix_values[9], matrix_values[10], matrix_values[11]]
        scale = [
            math.sqrt(matrix_values[0]**2 + matrix_values[3]**2 + matrix_values[6]**2),
            math.sqrt(matrix_values[1]**2 + matrix_values[4]**2 + matrix_values[7]**2),
            math.sqrt(matrix_values[2]**2 + matrix_values[5]**2 + matrix_values[8]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(matrix_values[i*3+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 64
    except:
        return None

def try_parse_euler_angles(data, offset):
    try:
        values = struct.unpack_from('<9f', data, offset)
        pos = list(values[0:3])
        euler = values[3:6]
        scale = list(values[6:9])
        
        cy = math.cos(euler[2] * 0.5)
        sy = math.sin(euler[2] * 0.5)
        cp = math.cos(euler[1] * 0.5)
        sp = math.sin(euler[1] * 0.5)
        cr = math.cos(euler[0] * 0.5)
        sr = math.sin(euler[0] * 0.5)
        
        quat = [
            sr * cp * cy - cr * sp * sy,
            cr * sp * cy + sr * cp * sy,
            cr * cp * sy - sr * sp * cy,
            cr * cp * cy + sr * sp * sy
        ]
        return pos, scale, quat, 36
    except:
        return None

def try_parse_axis_angle(data, offset):
    try:
        values = struct.unpack_from('<10f', data, offset)
        pos = list(values[0:3])
        axis = values[3:6]
        angle = values[6]
        scale = list(values[7:10])
        
        half_angle = angle * 0.5
        s = math.sin(half_angle)
        quat = [
            axis[0] * s,
            axis[1] * s,
            axis[2] * s,
            math.cos(half_angle)
        ]
        return pos, scale, quat, 40
    except:
        return None

def try_parse_dual_quaternion(data, offset):
    try:
        values = struct.unpack_from('<11f', data, offset)
        quat = list(values[0:4])
        dual = values[4:8]
        scale = list(values[8:11])
        
        pos = [
            2.0 * (-dual[3] * quat[0] + dual[0] * quat[3] - dual[1] * quat[2] + dual[2] * quat[1]),
            2.0 * (-dual[3] * quat[1] + dual[1] * quat[3] - dual[2] * quat[0] + dual[0] * quat[2]),
            2.0 * (-dual[3] * quat[2] + dual[2] * quat[3] - dual[0] * quat[1] + dual[1] * quat[0])
        ]
        return pos, scale, quat, 44
    except:
        return None

def try_parse_compact_quat(data, offset):
    try:
        values = struct.unpack_from('<9f', data, offset)
        pos = list(values[0:3])
        quat_compact = values[3:6]
        scale = list(values[6:9])
        
        w_squared = 1.0 - (quat_compact[0]**2 + quat_compact[1]**2 + quat_compact[2]**2)
        if w_squared < 0:
            w_squared = 0
        quat = [quat_compact[0], quat_compact[1], quat_compact[2], math.sqrt(w_squared)]
        return pos, scale, quat, 36
    except:
        return None

def try_parse_1int_3f_4f_3f(data, offset):
    try:
        values = struct.unpack_from('<I3f4f3f', data, offset)
        pos = list(values[1:4])
        quat = list(values[4:8])
        scale = list(values[8:11])
        return pos, scale, quat, 44
    except:
        return None

def try_parse_2int_3f_4f_3f(data, offset):
    try:
        values = struct.unpack_from('<II3f4f3f', data, offset)
        pos = list(values[2:5])
        quat = list(values[5:9])
        scale = list(values[9:12])
        return pos, scale, quat, 48
    except:
        return None

def try_parse_variable_header_16f(data, offset):
    for header_size in [1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 28, 32]:
        try:
            values = struct.unpack_from(f'<{header_size}B16f', data, offset)
            matrix_values = values[header_size:]
            pos = [matrix_values[12], matrix_values[13], matrix_values[14]]
            scale = [
                math.sqrt(matrix_values[0]**2 + matrix_values[4]**2 + matrix_values[8]**2),
                math.sqrt(matrix_values[1]**2 + matrix_values[5]**2 + matrix_values[9]**2),
                math.sqrt(matrix_values[2]**2 + matrix_values[6]**2 + matrix_values[10]**2)
            ]
            rot_matrix = []
            for i in range(3):
                for j in range(3):
                    rot_matrix.append(matrix_values[i*3+j] / scale[j] if scale[j] != 0 else 0)
            quat = quaternion_from_matrix(rot_matrix)
            if validate_transform(pos, scale, quat):
                return pos, scale, quat, header_size + 48
        except:
            continue
    return None

def try_parse_variable_header_10f(data, offset):
    for header_size in [1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 28, 32]:
        try:
            values = struct.unpack_from(f'<{header_size}B10f', data, offset)
            pos = list(values[header_size:header_size+3])
            quat = list(values[header_size+3:header_size+7])
            scale = list(values[header_size+7:header_size+10])
            if validate_transform(pos, scale, quat):
                return pos, scale, quat, header_size + 40
        except:
            continue
    return None

def try_parse_row_major_3x3_plus_pos_scale(data, offset):
    try:
        values = struct.unpack_from('<15f', data, offset)
        rot_matrix = list(values[0:9])
        pos = list(values[9:12])
        scale = list(values[12:15])
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 60
    except:
        return None

def try_parse_col_major_3x3_plus_pos_scale(data, offset):
    try:
        values = struct.unpack_from('<15f', data, offset)
        rot_matrix = []
        for col in range(3):
            for row in range(3):
                rot_matrix.append(values[row*3+col])
        pos = list(values[9:12])
        scale = list(values[12:15])
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 60
    except:
        return None

def try_parse_split_matrix(data, offset):
    try:
        values = struct.unpack_from('<9f3f3f', data, offset)
        rot_matrix = list(values[0:9])
        pos = list(values[9:12])
        scale = list(values[12:15])
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 60
    except:
        return None

def try_parse_packed_transform(data, offset):
    try:
        values = struct.unpack_from('<3f3f4f', data, offset)
        pos = list(values[0:3])
        scale = list(values[3:6])
        quat = list(values[6:10])
        return pos, scale, quat, 40
    except:
        return None

def try_parse_inverted_4x4(data, offset):
    try:
        values = struct.unpack_from('<16f', data, offset)
        inv_matrix = []
        for i in range(16):
            inv_matrix.append(values[i])
        
        det = (inv_matrix[0] * (inv_matrix[5] * inv_matrix[10] - inv_matrix[6] * inv_matrix[9]) -
               inv_matrix[1] * (inv_matrix[4] * inv_matrix[10] - inv_matrix[6] * inv_matrix[8]) +
               inv_matrix[2] * (inv_matrix[4] * inv_matrix[9] - inv_matrix[5] * inv_matrix[8]))
        
        if abs(det) < 0.0001:
            return None
            
        pos = [-inv_matrix[12], -inv_matrix[13], -inv_matrix[14]]
        scale = [
            1.0 / math.sqrt(inv_matrix[0]**2 + inv_matrix[4]**2 + inv_matrix[8]**2),
            1.0 / math.sqrt(inv_matrix[1]**2 + inv_matrix[5]**2 + inv_matrix[9]**2),
            1.0 / math.sqrt(inv_matrix[2]**2 + inv_matrix[6]**2 + inv_matrix[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(inv_matrix[i*4+j] * scale[j])
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 64
    except:
        return None

def try_parse_decomposed_transform(data, offset):
    try:
        values = struct.unpack_from('<3f4f3f3f', data, offset)
        pos = list(values[0:3])
        quat = list(values[3:7])
        scale = list(values[7:10])
        translation_offset = list(values[10:13])
        actual_pos = [pos[i] + translation_offset[i] for i in range(3)]
        return actual_pos, scale, quat, 52
    except:
        return None

def try_parse_trs_with_pivot(data, offset):
    try:
        values = struct.unpack_from('<3f4f3f3f', data, offset)
        pivot = list(values[0:3])
        quat = list(values[3:7])
        scale = list(values[7:10])
        pos = list(values[10:13])
        return pos, scale, quat, 52
    except:
        return None

def try_parse_half_precision(data, offset):
    try:
        import struct
        values = []
        for i in range(20):
            half_val = struct.unpack_from('<H', data, offset + i*2)[0]
            sign = (half_val >> 15) & 1
            exp = (half_val >> 10) & 0x1f
            frac = half_val & 0x3ff
            
            if exp == 0:
                if frac == 0:
                    f = 0.0
                else:
                    f = (frac / 1024.0) * (2**(-14))
            elif exp == 31:
                if frac == 0:
                    f = float('inf')
                else:
                    f = float('nan')
            else:
                f = ((1.0 + frac / 1024.0)) * (2**(exp - 15))
            
            if sign:
                f = -f
            values.append(f)
        
        pos = values[0:3]
        quat = values[3:7]
        scale = values[7:10]
        return pos, scale, quat, 40
    except:
        return None

def try_parse_aligned_64(data, offset):
    try:
        values = struct.unpack_from('<16f', data, offset)
        pos = [values[12], values[13], values[14]]
        scale = [
            math.sqrt(values[0]**2 + values[4]**2 + values[8]**2),
            math.sqrt(values[1]**2 + values[5]**2 + values[9]**2),
            math.sqrt(values[2]**2 + values[6]**2 + values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 64
    except:
        return None

def try_parse_aligned_80(data, offset):
    try:
        values = struct.unpack_from('<20f', data, offset)
        pos = [values[12], values[13], values[14]]
        scale = [
            math.sqrt(values[0]**2 + values[4]**2 + values[8]**2),
            math.sqrt(values[1]**2 + values[5]**2 + values[9]**2),
            math.sqrt(values[2]**2 + values[6]**2 + values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 80
    except:
        return None

def try_parse_aligned_96(data, offset):
    try:
        values = struct.unpack_from('<24f', data, offset)
        pos = [values[12], values[13], values[14]]
        scale = [
            math.sqrt(values[0]**2 + values[4]**2 + values[8]**2),
            math.sqrt(values[1]**2 + values[5]**2 + values[9]**2),
            math.sqrt(values[2]**2 + values[6]**2 + values[10]**2)
        ]
        rot_matrix = []
        for i in range(3):
            for j in range(3):
                rot_matrix.append(values[i*4+j] / scale[j] if scale[j] != 0 else 0)
        quat = quaternion_from_matrix(rot_matrix)
        return pos, scale, quat, 96
    except:
        return None

def try_parse_compressed_quat(data, offset):
    try:
        values = struct.unpack_from('<3f3I3f', data, offset)
        pos = list(values[0:3])
        
        qx = (values[3] / 2147483647.0) * 2.0 - 1.0
        qy = (values[4] / 2147483647.0) * 2.0 - 1.0
        qz = (values[5] / 2147483647.0) * 2.0 - 1.0
        qw_squared = 1.0 - (qx**2 + qy**2 + qz**2)
        if qw_squared < 0:
            qw_squared = 0
        quat = [qx, qy, qz, math.sqrt(qw_squared)]
        
        scale = list(values[6:9])
        return pos, scale, quat, 36
    except:
        return None

def try_parse_nested_structure(data, offset):
    try:
        values = struct.unpack_from('<I3fI4fI3f', data, offset)
        if values[0] == 1 and values[4] == 2 and values[9] == 3:
            pos = list(values[1:4])
            quat = list(values[5:9])
            scale = list(values[10:13])
            return pos, scale, quat, 52
    except:
        pass
    return None

def try_parse_string_prefixed(data, offset):
    try:
        str_len = struct.unpack_from('<I', data, offset)[0]
        if str_len > 0 and str_len < 256:
            offset += 4 + str_len
            values = struct.unpack_from('<16f', data, offset)
            pos = [values[12], values[13], values[14]]
            scale = [
                math.sqrt(values[0]**2 + values[4]**2 + values[8]**2),
                math.sqrt(values[1]**2 + values[5]**2 + values[9]**2),
                math.sqrt(values[2]**2 + values[6]**2 + values[10]**2)
            ]
            rot_matrix = []
            for i in range(3):
                for j in range(3):
                    rot_matrix.append(values[i*4+j] / scale[j] if scale[j] != 0 else 0)
            quat = quaternion_from_matrix(rot_matrix)
            return pos, scale, quat, 4 + str_len + 64
    except:
        pass
    return None

def try_parse_double_precision(data, offset):
    try:
        values = struct.unpack_from('<10d', data, offset)
        pos = [float(values[0]), float(values[1]), float(values[2])]
        quat = [float(values[3]), float(values[4]), float(values[5]), float(values[6])]
        scale = [float(values[7]), float(values[8]), float(values[9])]
        return pos, scale, quat, 80
    except:
        return None

def try_parse_mixed_precision(data, offset):
    try:
        values = struct.unpack_from('<3d4f3f', data, offset)
        pos = [float(values[0]), float(values[1]), float(values[2])]
        quat = list(values[3:7])
        scale = list(values[7:10])
        return pos, scale, quat, 52
    except:
        return None

def try_parse_bitpacked(data, offset):
    try:
        packed_data = struct.unpack_from('<Q', data, offset)[0]
        
        pos_x = ((packed_data >> 0) & 0x3FF) / 10.0 - 50.0
        pos_y = ((packed_data >> 10) & 0x3FF) / 10.0 - 50.0
        pos_z = ((packed_data >> 20) & 0x3FF) / 10.0 - 50.0
        
        rot_bits = (packed_data >> 30) & 0x3FF
        angle = (rot_bits / 1023.0) * math.pi * 2
        
        quat = [0, 0, math.sin(angle/2), math.cos(angle/2)]
        
        scale_bits = (packed_data >> 40) & 0xFF
        scale_val = 0.5 + (scale_bits / 255.0) * 2.0
        
        pos = [pos_x, pos_y, pos_z]
        scale = [scale_val, scale_val, scale_val]
        
        return pos, scale, quat, 8
    except:
        return None

def try_parse_morton_encoded(data, offset):
    try:
        morton = struct.unpack_from('<Q', data, offset)[0]
        
        def decode_morton3(morton):
            x = morton & 0x9249249249249249
            x = (x | (x >> 2)) & 0x30C30C30C30C30C3
            x = (x | (x >> 4)) & 0xF00F00F00F00F00F
            x = (x | (x >> 8)) & 0x00FF0000FF0000FF
            x = (x | (x >> 16)) & 0x00000000FFFFFFFF
            
            y = (morton >> 1) & 0x9249249249249249
            y = (y | (y >> 2)) & 0x30C30C30C30C30C3
            y = (y | (y >> 4)) & 0xF00F00F00F00F00F
            y = (y | (y >> 8)) & 0x00FF0000FF0000FF
            y = (y | (y >> 16)) & 0x00000000FFFFFFFF
            
            z = (morton >> 2) & 0x9249249249249249
            z = (z | (z >> 2)) & 0x30C30C30C30C30C3
            z = (z | (z >> 4)) & 0xF00F00F00F00F00F
            z = (z | (z >> 8)) & 0x00FF0000FF0000FF
            z = (z | (z >> 16)) & 0x00000000FFFFFFFF
            
            return x, y, z
        
        x, y, z = decode_morton3(morton)
        pos = [x / 1000.0, y / 1000.0, z / 1000.0]
        
        values = struct.unpack_from('<4f3f', data, offset + 8)
        quat = list(values[0:4])
        scale = list(values[4:7])
        
        return pos, scale, quat, 36
    except:
        return None
        
def is_fourcc(data, offset):
    if offset+4 > len(data): 
        return False
    chunk = data[offset:offset+4]
    return all(65 <= b <= 90 for b in chunk)  # 'A'..'Z'
    
def parse_lpmt_block(filename):
    with open(filename, 'rb') as f:
        data = f.read()

    lpmt_pos = data.find(b'LPMT')
    if lpmt_pos == -1:
        print("LPMT block not found")
        return

    entry_count = struct.unpack_from('<I', data, lpmt_pos + 4)[0]
    print(f"LPMT block found at 0x{lpmt_pos:X}")
    print(f"Header entry_count: {entry_count}")
    print()

    base_offset = lpmt_pos + 8
    current_offset = base_offset
    
    parsers = [
        ("4x4_matrix", "try_parse_4x4_matrix"),
        ("3x4_matrix", "try_parse_3x4_matrix"),
        ("pos_quat_scale", "try_parse_pos_quat_scale"),
        ("quat_pos_scale", "try_parse_quat_pos_scale"),
        ("scale_pos_quat", "try_parse_scale_pos_quat"),
        ("1int+16f", "try_parse_1int_16f"),
        ("2int+16f", "try_parse_2int_16f"),
        ("1int+12f", "try_parse_1int_12f"),
        ("2int+12f", "try_parse_2int_12f"),
        ("4byte_pad+16f", "try_parse_4byte_pad_16f"),
        ("8byte_pad+12f", "try_parse_8byte_pad_12f"),
        ("1short+16f", "try_parse_1short_16f"),
        ("2short+16f", "try_parse_2short_16f"),
        ("1byte+16f", "try_parse_1byte_16f"),
        ("4byte+16f", "try_parse_4byte_16f"),
        ("transposed_4x4", "try_parse_transposed_4x4"),
        ("transposed_3x4", "try_parse_transposed_3x4"),
        ("1int+10f", "try_parse_1int_10f"),
        ("2int+10f", "try_parse_2int_10f"),
        ("16byte_pad+16f", "try_parse_16byte_pad_16f"),
        ("12byte_pad+12f", "try_parse_12byte_pad_12f"),
        ("3int+16f", "try_parse_3int_16f"),
        ("4int+12f", "try_parse_4int_12f"),
        ("euler_angles", "try_parse_euler_angles"),
        ("axis_angle", "try_parse_axis_angle"),
        ("dual_quaternion", "try_parse_dual_quaternion"),
        ("compact_quat", "try_parse_compact_quat"),
        ("1int+3f+4f+3f", "try_parse_1int_3f_4f_3f"),
        ("2int+3f+4f+3f", "try_parse_2int_3f_4f_3f"),
        ("var_header+16f", "try_parse_variable_header_16f"),
        ("var_header+12f", "try_parse_variable_header_12f"),
        ("var_header+10f", "try_parse_variable_header_10f"),
        ("row_3x3+pos+scale", "try_parse_row_major_3x3_plus_pos_scale"),
        ("col_3x3+pos+scale", "try_parse_col_major_3x3_plus_pos_scale"),
        ("split_matrix", "try_parse_split_matrix"),
        ("packed_transform", "try_parse_packed_transform"),
        ("inverted_4x4", "try_parse_inverted_4x4"),
        ("decomposed_trans", "try_parse_decomposed_transform"),
        ("trs_with_pivot", "try_parse_trs_with_pivot"),
        ("half_precision", "try_parse_half_precision"),
        ("aligned_64", "try_parse_aligned_64"),
        ("aligned_80", "try_parse_aligned_80"),
        ("aligned_96", "try_parse_aligned_96"),
        ("compressed_quat", "try_parse_compressed_quat"),
        ("nested_structure", "try_parse_nested_structure"),
        ("string_prefixed", "try_parse_string_prefixed"),
        ("double_precision", "try_parse_double_precision"),
        ("mixed_precision", "try_parse_mixed_precision"),
        ("bitpacked", "try_parse_bitpacked"),
        ("morton_encoded", "try_parse_morton_encoded")
    ]

    
    entry_idx = 0
    while current_offset < len(data):
        if is_fourcc(data, current_offset):
            print(f"Next FourCC tag at 0x{current_offset:X}, stopping LPMT parsing")
            break

        print(f"===== Entry {entry_idx} @ 0x{current_offset:X} =====")
        found = False
        for layout_name, parser_name in parsers:
            parser_func = globals().get(parser_name)
            if not parser_func:
                continue
            result = parser_func(data, current_offset)
            if result:
                pos, scale, quat, size = result
                quat_len = math.sqrt(sum(q*q for q in quat))
                is_valid = validate_transform(pos, scale, quat)
                print(f"Entry {entry_idx} @ offset 0x{current_offset:X}")
                print(f"  Layout: {layout_name}")
                print(f"  Pos: [{pos[0]:.3f}, {pos[1]:.3f}, {pos[2]:.3f}]")
                print(f"  Scale: [{scale[0]:.3f}, {scale[1]:.3f}, {scale[2]:.3f}]")
                print(f"  Quat: [{quat[0]:.3f}, {quat[1]:.3f}, {quat[2]:.3f}, {quat[3]:.3f}]")
                print(f"  QuatLen: {quat_len:.3f}")
                print(f"  Valid: {'YES' if is_valid else 'NO'}\n")
                current_offset += size
                entry_idx += 1
                found = True
                break
        if not found:
            current_offset += 4
            
        entry_idx += 1

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("file", nargs="?", default="test.map")
    args = ap.parse_args()
    if not os.path.isfile(args.file):
        print(f"File not found: {args.file}")
        sys.exit(1)
    parse_lpmt_block(args.file)


def try_parse_variable_header_12f(data, offset):
    for header_size in [1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 28, 32]:
        try:
            values = struct.unpack_from(f'<{header_size}B12f', data, offset)
            mv = values[header_size:]
            r00, r01, r02, tx, r10, r11, r12, ty, r20, r21, r22, tz = mv
            sx = math.sqrt(r00*r00 + r10*r10 + r20*r20)
            sy = math.sqrt(r01*r01 + r11*r11 + r21*r21)
            sz = math.sqrt(r02*r02 + r12*r12 + r22*r22)
            if sx == 0 or sy == 0 or sz == 0:
                continue
            rot_matrix = [
                r00/sx, r01/sy, r02/sz,
                r10/sx, r11/sy, r12/sz,
                r20/sx, r21/sy, r22/sz
            ]
            pos = [tx, ty, tz]
            scale = [sx, sy, sz]
            quat = quaternion_from_matrix(rot_matrix)
            if validate_transform(pos, scale, quat):
                return pos, scale, quat, header_size + 48
        except:
            continue
    return None
    
def try_parse_pos_3f_quat_4h_scale_3f(data, offset):
    try:
        vals = struct.unpack_from('<3f4h3f', data, offset)
        pos = list(vals[0:3])
        qi = vals[3:7]
        scale = list(vals[7:10])
        quat = [qi[0]/32767.0, qi[1]/32767.0, qi[2]/32767.0, qi[3]/32767.0]
        ln = math.sqrt(quat[0]*quat[0] + quat[1]*quat[1] + quat[2]*quat[2] + quat[3]*quat[3])
        if ln == 0:
            return None
        quat = [quat[0]/ln, quat[1]/ln, quat[2]/ln, quat[3]/ln]
        if validate_transform(pos, scale, quat):
            return pos, scale, quat, 32
    except:
        return None

def try_parse_pos_3f_quat_4H_scale_3f(data, offset):
    try:
        vals = struct.unpack_from('<3f4H3f', data, offset)
        pos = list(vals[0:3])
        qu = vals[3:7]
        scale = list(vals[7:10])
        quat = [(qu[0]/65535.0)*2.0-1.0, (qu[1]/65535.0)*2.0-1.0, (qu[2]/65535.0)*2.0-1.0, (qu[3]/65535.0)*2.0-1.0]
        ln = math.sqrt(quat[0]*quat[0] + quat[1]*quat[1] + quat[2]*quat[2] + quat[3]*quat[3])
        if ln == 0:
            return None
        quat = [quat[0]/ln, quat[1]/ln, quat[2]/ln, quat[3]/ln]
        if validate_transform(pos, scale, quat):
            return pos, scale, quat, 32
    except:
        return None

def try_parse_fixed_pos_i32_quat_i16_scale_i16(data, offset):
    try:
        x, y, z, qx, qy, qz, qw, sx, sy, sz = struct.unpack_from('<3i4h3h', data, offset)
        for pd in (1000.0, 1024.0, 4096.0, 16384.0):
            pos = [x/pd, y/pd, z/pd]
            for sd in (100.0, 256.0, 1000.0, 1024.0, 4096.0):
                scale = [max(1e-6, sx/sd), max(1e-6, sy/sd), max(1e-6, sz/sd)]
                quat = [qx/32767.0, qy/32767.0, qz/32767.0, qw/32767.0]
                ln = math.sqrt(quat[0]*quat[0] + quat[1]*quat[1] + quat[2]*quat[2] + quat[3]*quat[3])
                if ln == 0:
                    continue
                qn = [quat[0]/ln, quat[1]/ln, quat[2]/ln, quat[3]/ln]
                if validate_transform(pos, scale, qn):
                    return pos, scale, qn, 12 + 8 + 6
    except:
        pass
    return None

def try_parse_fixed_all_i16(data, offset):
    try:
        px, py, pz, qx, qy, qz, qw, sx, sy, sz = struct.unpack_from('<3h4h3h', data, offset)
        for pd in (10.0, 50.0, 100.0, 256.0, 512.0, 1000.0, 1024.0, 4096.0):
            pos = [px/pd, py/pd, pz/pd]
            for sd in (10.0, 100.0, 256.0, 1000.0, 1024.0, 4096.0):
                scale = [max(1e-6, sx/sd), max(1e-6, sy/sd), max(1e-6, sz/sd)]
                quat = [qx/32767.0, qy/32767.0, qz/32767.0, qw/32767.0]
                ln = math.sqrt(quat[0]*quat[0] + quat[1]*quat[1] + quat[2]*quat[2] + quat[3]*quat[3])
                if ln == 0:
                    continue
                qn = [quat[0]/ln, quat[1]/ln, quat[2]/ln, quat[3]/ln]
                if validate_transform(pos, scale, qn):
                    return pos, scale, qn, 20
    except:
        pass
    return None

def try_parse_1int_3f_4h_3f(data, offset):
    try:
        vals = struct.unpack_from('<I3f4h3f', data, offset)
        pos = list(vals[1:4])
        qi = vals[4:8]
        scale = list(vals[8:11])
        quat = [qi[0]/32767.0, qi[1]/32767.0, qi[2]/32767.0, qi[3]/32767.0]
        ln = math.sqrt(quat[0]*quat[0] + quat[1]*quat[1] + quat[2]*quat[2] + quat[3]*quat[3])
        if ln == 0:
            return None
        quat = [quat[0]/ln, quat[1]/ln, quat[2]/ln, quat[3]/ln]
        if validate_transform(pos, scale, quat):
            return pos, scale, quat, 36
    except:
        return None

def try_parse_2int_3f_4h_3f(data, offset):
    try:
        vals = struct.unpack_from('<II3f4h3f', data, offset)
        pos = list(vals[2:5])
        qi = vals[5:9]
        scale = list(vals[9:12])
        quat = [qi[0]/32767.0, qi[1]/32767.0, qi[2]/32767.0, qi[3]/32767.0]
        ln = math.sqrt(quat[0]*quat[0] + quat[1]*quat[1] + quat[2]*quat[2] + quat[3]*quat[3])
        if ln == 0:
            return None
        quat = [quat[0]/ln, quat[1]/ln, quat[2]/ln, quat[3]/ln]
        if validate_transform(pos, scale, quat):
            return pos, scale, quat, 40
    except:
        return None
  