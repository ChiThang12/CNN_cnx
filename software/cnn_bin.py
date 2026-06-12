"""
HỆ THỐNG PHÂN LOẠI MÃ ĐỘC DỰA TRÊN KIẾN TRÚC MẠNG CONVOLUTIONAL NEURAL NETWORK (CNN)
Định dạng ảnh đầu vào: 8x32x1
"""

# ==========================================
# 1. KHAI BÁO THƯ VIỆN (IMPORTS)
# ==========================================
import os
import sys
import glob
import random
import time
import json
import math
import numpy as np
import pandas as pd
from PIL import Image

# Sử dụng tensorflow.keras 
import tensorflow as tf
from tensorflow.keras.models import Sequential
from tensorflow.keras.layers import Dense, Dropout, Flatten, Conv2D, MaxPooling2D
from tensorflow.keras.utils import plot_model

from sklearn.model_selection import train_test_split
from sklearn.metrics import confusion_matrix, classification_report
import matplotlib.pyplot as plt
import seaborn as sns
import openpyxl

# ==========================================
# 2. ĐỌC VÀ CÂN BẰNG DỮ LIỆU (DATA BALANCING)
# ==========================================
if len(sys.argv) < 3:
    print("Error: Vui lòng cung cấp đường dẫn dataset và random seed.")
    print("Cú pháp: python script.py <path_to_dataset> <random_seed>")
    sys.exit(1)

ds = str(sys.argv[1])
rd_seed = int(sys.argv[2])       # Đồng bộ hóa seed từ hệ thống điều khiển trung tâm
original_dir = os.getcwd()       # Lưu lại thư mục gốc để khôi phục sau khi đọc dữ liệu

try:
    os.chdir(ds)                 # Di chuyển vào phân vùng dữ liệu ảnh
except FileNotFoundError:
    print(f"Error: Thư mục dataset '{ds}' không tồn tại.")
    sys.exit(1)

list_fams = os.listdir(os.getcwd()) 
benign_paths = []
malware_paths = []

# Bước 2.1: Gom đường dẫn file (Tránh load toàn bộ ảnh lên RAM gây overload)
for fam_name in list_fams:
    if not os.path.isdir(fam_name): 
        continue
    
    img_list = glob.glob(os.path.join(fam_name, '*.png'))
    if fam_name.lower() == 'benign':
        benign_paths.extend(img_list)
    else:
        malware_paths.extend(img_list)

# Bước 2.2: Cân bằng dữ liệu theo tỷ lệ cấu hình (Malware = 2 * Benign)
num_benign = len(benign_paths)
target_malware = num_benign * 2

print(f"Tổng số ảnh Benign gốc: {num_benign}")
print(f"Tổng số ảnh Malware gốc: {len(malware_paths)}")

if len(malware_paths) > target_malware:
    random.seed(rd_seed)         # Đóng băng seed phục vụ kiểm thử hồi quy (Regression Testing)
    malware_paths = random.sample(malware_paths, target_malware)

print(f"=> Số ảnh Malware sau cân bằng (Downsampling): {len(malware_paths)}")

# Bước 2.3: Pipeline tiền xử lý và số hóa dữ liệu (ETL Process)
X = []
y = []

# Đọc tập Benign (Label One-hot: [1, 0])
for img_path in benign_paths:
    with Image.open(img_path) as im:
        im1 = im.resize((8, 32), Image.Resampling.LANCZOS) 
        X.append(np.array(im1))
        y.append([1, 0])

# Đọc tập Malware (Label One-hot: [0, 1])
for img_path in malware_paths:
    with Image.open(img_path) as im:
        im1 = im.resize((8, 32), Image.Resampling.LANCZOS) 
        X.append(np.array(im1))
        y.append([0, 1])

# Khôi phục ngữ cảnh thư mục làm việc ban đầu
os.chdir(original_dir)

# Chuẩn hóa dữ liệu pixel về khoảng [0, 1] nhằm tăng tốc độ hội tụ mạng neural
X = np.array(X).astype('float32') / 255.0
y = np.array(y)

total_samples = len(X)
X = X.reshape(total_samples, 8, 32, 1)  # Định hình lại tensor theo Hardware Blueprint (8x32x1 kênh đơn)

print(f"Tổng số mẫu đưa vào huấn luyện (Total Samples): {total_samples}")
print(f"Kích thước X: {X.shape} | Kích thước y: {y.shape}")

# ==========================================
# 3. PHÂN CHIA DỮ LIỆU (DATA SPLITTING)
# ==========================================
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.3, random_state=rd_seed)

print("\n" + "-"*45)
print("THỐNG KÊ SỐ LƯỢNG ẢNH CỦA 2 LỚP")
print("-"*45)
benign_total = int(np.sum(y[:, 0]))
malware_total = int(np.sum(y[:, 1]))
print(f"TỔNG CỘNG (Dataset) : Benign = {benign_total} | Malware = {malware_total}")

benign_train = int(np.sum(y_train[:, 0]))
malware_train = int(np.sum(y_train[:, 1]))
print(f"-> Đưa vào TRAIN    : Benign = {benign_train} | Malware = {malware_train}")

benign_test = int(np.sum(y_test[:, 0]))
malware_test = int(np.sum(y_test[:, 1]))
print(f"-> Đưa vào TEST     : Benign = {benign_test} | Malware = {malware_test}")
print("-"*45 + "\n")

# ==========================================
# 4. KHỞI TẠO VÀ HUẤN LUYỆN MÔ HÌNH (CNN)
# ==========================================
batch_size = 32 
epochs = 10

# Xây dựng kiến trúc mạng đồng bộ phần cứng
malware_model = Sequential()

malware_model.add(Conv2D(16, kernel_size=(3, 3), strides=(1, 1), padding='valid', activation='relu', input_shape=(8, 32, 1), name='Conv2D_1'))
malware_model.add(MaxPooling2D(pool_size=(2, 2), name='MaxPooling_1'))
malware_model.add(Conv2D(32, kernel_size=(3, 3), strides=(1, 1), padding='valid', activation='relu', name='Conv2D_2'))
malware_model.add(Flatten(name='Flatten_Core'))
malware_model.add(Dense(48, activation='relu', name='Dense_1'))
malware_model.add(Dense(2, activation='softmax', name='Dense_2'))

# Biên dịch mô hình với thuật toán tối ưu Adam
malware_model.compile(loss='categorical_crossentropy', optimizer='adam', metrics=['accuracy'])

print("Bắt đầu huấn luyện mô hình...")
tic = time.time()
history = malware_model.fit(X_train, y_train,
                            batch_size=batch_size,
                            epochs=epochs,
                            verbose=1,
                            validation_split=0.2)
toc = time.time()
print(f'Thời gian huấn luyện (Training time): {toc - tic:.4f} giây')

# Lưu trữ mô hình gốc dạng H5
malware_model.save("cnn_bin_balanced_hardware_model.h5")
malware_model.summary()

# ==========================================
# 5. ĐÁNH GIÁ MÔ HÌNH & XUẤT BÁO CÁO (EVALUATION)
# ==========================================
tic = time.time()
y_predict = malware_model.predict(X_test, batch_size=batch_size, verbose=0)
toc = time.time()
print(f'Thời gian suy luận (Testing time): {toc - tic:.4f} giây')

test_eval = malware_model.evaluate(X_test, y_test, verbose=0)
print(f'Độ chính xác tập kiểm thử (Test Accuracy): {test_eval[1]:.4f}')
print(f'Giá trị hàm mất mát (Test Loss): {test_eval[0]:.4f}')

print("\n" + "="*50)
print("BÁO CÁO ĐÁNH GIÁ PHÂN LOẠI (CLASSIFICATION REPORT)")
print("="*50)

y_true_classes = y_test.argmax(axis=1)
y_pred_classes = y_predict.argmax(axis=1)
target_names = ['Benign', 'Malware']

print(classification_report(y_true_classes, y_pred_classes, target_names=target_names))

# Tính toán ma trận nhầm lẫn (Confusion Matrix)
conf_mat = confusion_matrix(y_true_classes, y_pred_classes)
conf_mat_norm = conf_mat.astype('float') / conf_mat.sum(axis=1)[:, np.newaxis]
conf_mat2 = np.around(conf_mat_norm, decimals=2)

print("Ma trận nhầm lẫn gốc (Raw Confusion Matrix):")
print(conf_mat)

# Vẽ ma trận nhầm lẫn dạng thô (Raw Matrix)
plt.figure(figsize=(6, 5))
sns.heatmap(conf_mat, annot=True, fmt='d', cmap='Oranges', xticklabels=target_names, yticklabels=target_names)
plt.title('Raw Confusion Matrix (Balanced)')
plt.ylabel('True Label')
plt.xlabel('Predicted Label')
plt.tight_layout()
plt.savefig('raw_confusion_matrix_balanced.png', dpi=300)
plt.close()

# Vẽ ma trận nhầm lẫn dạng chuẩn hóa (Normalized Matrix)
plt.figure(figsize=(6, 5))
sns.heatmap(conf_mat2, annot=True, fmt='.2f', cmap='Blues', xticklabels=target_names, yticklabels=target_names)
plt.title('Normalized Confusion Matrix (Balanced)')
plt.ylabel('True Label')
plt.xlabel('Predicted Label')
plt.tight_layout()
plt.savefig('normalized_confusion_matrix_balanced.png', dpi=300)
plt.close()

# Xuất dữ liệu ma trận sang tệp tin phân tích .dat
os.makedirs('./dat', exist_ok=True)
with open('./dat/conf_mat_cnn_balanced.dat', 'wb') as f:
    for line in np.matrix(conf_mat2):
        np.savetxt(f, line, fmt='%.2f')


# ==========================================
# 6. HÀM XUẤT THAM SỐ VÀ TRỌNG SỐ (EXPORT SYSTEM)
# ==========================================

def save_weights_to_json(model: tf.keras.Model, filename: str = "malware_model_weights.json") -> None:
    """Lưu toàn bộ trọng số (Weights) và độ lệch (Biases) của mạng dưới dạng tệp JSON."""
    weights_dict = {}
    for layer in model.layers:
        weights = layer.get_weights()
        if len(weights) > 0:
            weights_dict[f'{layer.name}_Weights'] = weights[0].tolist()
            weights_dict[f'{layer.name}_Biases'] = weights[1].tolist()
            
    with open(filename, 'w', encoding='utf-8') as json_file:
        json.dump(weights_dict, json_file, indent=4)
    print(f"-> Đã lưu trọng số vào tệp JSON: {filename}")


def save_weights_to_excel(model: tf.keras.Model, filename: str = "malware_model_weights.xlsx") -> None:
    """Lưu cấu trúc ma trận trọng số mạng Neural vào các Sheet riêng biệt trong Excel."""
    with pd.ExcelWriter(filename, engine='openpyxl') as writer:
        for layer in model.layers:
            weights = layer.get_weights()
            if len(weights) > 0:
                w, b = weights[0], weights[1]
                pd.DataFrame(w.reshape(-1, w.shape[-1])).to_excel(writer, sheet_name=f'{layer.name}_Weights')
                pd.DataFrame(b.reshape(-1, 1)).to_excel(writer, sheet_name=f'{layer.name}_Biases')
    print(f"-> Đã lưu ma trận trọng số vào tệp Excel: {filename}")


def save_layer_parameters_to_json(model: tf.keras.Model, filename: str = "malware_balanced_parameters.json") -> None:
    """
    Trích xuất cấu hình siêu tham số của từng Layer mạng và xuất ra JSON.
    Hỗ trợ an toàn cho cả Keras 2 và Keras 3.
    """
    layers_info = []
    for i, layer in enumerate(model.layers):
        try:
            in_shape = str(layer.input_shape)
            out_shape = str(layer.output_shape)
        except AttributeError:
            in_shape = str(layer.input.shape) if hasattr(layer, 'input') else "Unknown"
            out_shape = str(layer.output.shape) if hasattr(layer, 'output') else "Unknown"

        info = {
            "index": i,
            "layer_name": layer.name,
            "layer_type": layer.__class__.__name__,
            "input_shape": in_shape,
            "output_shape": out_shape,
            "total_params": layer.count_params(),
            "trainable": layer.trainable
        }
        
        config = layer.get_config()
        fields_to_extract = ['activation', 'kernel_size', 'strides', 'padding', 'pool_size', 'units', 'filters']
        for field in fields_to_extract:
            if field in config:
                if field == 'activation' and hasattr(layer, 'activation') and layer.activation:
                    info[field] = layer.activation.__name__ if hasattr(layer.activation, '__name__') else str(layer.activation)
                else:
                    info[field] = config[field]
                    
        layers_info.append(info)
        
    with open(filename, 'w', encoding='utf-8') as json_file:
        json.dump(layers_info, json_file, indent=4, ensure_ascii=False)
    print(f"-> Đã lưu tham số cấu hình Layer vào tệp JSON: {filename}")


def save_layer_parameters_to_excel(model: tf.keras.Model, filename: str = "malware_balanced_parameters.xlsx") -> None:
    """Tổng hợp metadata cấu trúc phần cứng của các Layer thành một bảng tường minh trong Excel."""
    layers_summary = []
    for i, layer in enumerate(model.layers):
        config = layer.get_config()
        
        try:
            in_shape = str(layer.input_shape)
            out_shape = str(layer.output_shape)
        except AttributeError:
            in_shape = str(layer.input.shape) if hasattr(layer, 'input') else "Unknown"
            out_shape = str(layer.output.shape) if hasattr(layer, 'output') else "Unknown"

        layer_dict = {
            "No.": i,
            "Layer Name": layer.name,
            "Layer Type": layer.__class__.__name__,
            "Input Shape": in_shape,
            "Output Shape": out_shape,
            "Filters/Units": config.get('filters', config.get('units', '-')),
            "Kernel/Pool Size": str(config.get('kernel_size', config.get('pool_size', '-'))),
            "Strides": str(config.get('strides', '-')),
            "Padding": config.get('padding', '-'),
            "Activation": layer.activation.__name__ if hasattr(layer, 'activation') and layer.activation and hasattr(layer.activation, '__name__') else '-',
            "Total Params": layer.count_params()
        }
        layers_summary.append(layer_dict)
        
    df = pd.DataFrame(layers_summary)
    
    if os.path.exists(filename):
        with pd.ExcelWriter(filename, engine='openpyxl', mode='a', if_sheet_exists='replace') as writer:
            df.to_excel(writer, sheet_name='Layers_Architecture', index=False)
    else:
        with pd.ExcelWriter(filename, engine='openpyxl') as writer:
            df.to_excel(writer, sheet_name='Layers_Architecture', index=False)
            
    print(f"-> Đã lưu bảng kiến trúc phần cứng mạng vào tệp Excel: {filename}")


# ==========================================
# 7. KHỞI CHẠY TIẾN TRÌNH LƯU TRỮ TÀI LIỆU
# ==========================================
save_weights_to_json(malware_model, "malware_balanced_weights.json")
save_weights_to_excel(malware_model, "malware_balanced_weights.xlsx")

save_layer_parameters_to_json(malware_model, "malware_balanced_parameters.json")
save_layer_parameters_to_excel(malware_model, "malware_balanced_weights.xlsx") # Ghi tab cấu trúc vào cùng file Excel chứa trọng số