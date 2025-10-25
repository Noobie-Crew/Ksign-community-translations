//
//  FilesViewModel.swift
//  Ksign
//
//  Created by Nagata Asami on 5/22/25.
//



import SwiftUI
import UniformTypeIdentifiers
import Zip
import SWCompression
import ArArchiveKit
import Zsign

class FilesViewModel: ObservableObject {
    @Published var files: [FileItem] = []
    @Published var currentDirectory: URL
    @Published var selectedItems: Set<FileItem> = []
    @Published var isEditMode: EditMode = .inactive
    @Published var showingImporter = false
    @Published var selectedItem: FileItem?
    @Published var showDirectoryPicker = false
    
    
    init(directory: URL? = nil) {
        if let directory = directory {
            self.currentDirectory = directory
        } else if let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            self.currentDirectory = documentsDirectory
        } else {
            self.currentDirectory = URL(fileURLWithPath: "")
        }
    }
    
    func loadFiles() {
        let fileManager = FileManager.default
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .fileSizeKey])
            
            files = contents.compactMap { url in
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .fileSizeKey])
                    let isDirectory = resourceValues.isDirectory ?? false
                    let creationDate = resourceValues.creationDate
                    let size = resourceValues.fileSize ?? 0
                    
                    return FileItem(
                        name: url.lastPathComponent,
                        url: url,
                        size: Int64(size),
                        creationDate: creationDate,
                        isDirectory: isDirectory
                    )
                } catch {
                    print("Error getting file attributes: \(error)")
                    return nil
                }
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        } catch {
            DispatchQueue.main.async {
                UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Error loading files: \(error.localizedDescription)"))
            }
        }
    }
    

    
    func deleteFile(_ fileItem: FileItem) {
        delete(items: [fileItem])
    }
    
    func deleteSelectedItems() {
        guard !selectedItems.isEmpty else { return }
        
        let itemsToDelete = Array(selectedItems)
        
        delete(items: itemsToDelete)

        selectedItems.removeAll()
        if isEditMode == .active {
            isEditMode = .inactive
        }
    }

    private func delete(items: [FileItem]) {
        guard !items.isEmpty else { return }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            var errorMessages: [String] = []
            
            for item in items {
                do {
                    try fileManager.removeItem(at: item.url)
                    
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            if let index = self.files.firstIndex(where: { $0.url == item.url }) {
                                self.files.remove(at: index)
                            }
                        }
                    }
                } catch {
                    errorMessages.append(item.name)
                }
            }
            
            DispatchQueue.main.async {
                if !errorMessages.isEmpty {
                    let count = errorMessages.count
                    UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Failed to delete \(count) item\(count == 1 ? "" : "s")"))
                }
            }
        }
    }
    
    func createNewFolder(name: String) {
        guard !name.isEmpty else { return }
        
        let sanitizedName = sanitizeFileName(name)
        let newFolderURL = currentDirectory.appendingPathComponent(sanitizedName)
        
        do {
            try FileManager.default.createDirectory(at: newFolderURL, withIntermediateDirectories: true, attributes: nil)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                loadFiles()
            }
        } catch {
            DispatchQueue.main.async {
                UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Error creating folder: \(error.localizedDescription)"))
            }
        }
    }
    
    func createNewTextFile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        let sanitizedName = sanitizeFileName(trimmed)
        let newURL = currentDirectory.appendingPathComponent(sanitizedName)
        let finalURL = generateUniqueFileName(for: newURL)
        
        do {
            try Data().write(to: finalURL)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                loadFiles()
            }       
        } catch {
            DispatchQueue.main.async {
                UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Error creating text file: \(error.localizedDescription)"))
            }
        }
    }
    
    func renameFile(newName: String, item: FileItem) {
        guard !newName.isEmpty else { return }
        
        let sanitizedName = sanitizeFileName(newName)
        let newURL = currentDirectory.appendingPathComponent(sanitizedName)
        
        do {
            try FileManager.default.moveItem(at: item.url, to: newURL)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                loadFiles()
            }
        } catch {
            DispatchQueue.main.async {
                UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Error renaming file: \(error.localizedDescription)"))
            }
        }
    }
    

    func importCertificate(_ file: FileItem) {
        guard file.isP12Certificate else { return }
        
        let provisionFile = CertificateService.shared.findProvisionFile(near: file)
        switch provisionFile {
        case .failure(let err):
            DispatchQueue.main.async { UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized(err.errorDescription ?? "Unknown error")) }
        case .success(let provisionFile):
            CertificateService.shared.importP12Certificate(p12File: file, provisionFile: provisionFile, password: "") { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let message):
                        UIAlertController.showAlertWithOk(title: .localized("Success"), message: .localized(message))
                    case .failure(let importError):
                        if case .invalidPassword = importError {
                            UIAlertController.showAlertWithTextBox(
                                title: .localized("Enter Certificate Password"),
                                message: .localized("Enter the password for the certificate. Leave it blank if no password is required."),
                                textFieldPlaceholder: .localized("Password"),
                                textFieldText: "",
                                submit: .localized("Import"),
                                cancel: .localized("Cancel"),
                                onSubmit: { password in
                                    CertificateService.shared.importP12Certificate(p12File: file, provisionFile: provisionFile, password: password) { result in
                                        DispatchQueue.main.async {
                                            switch result {
                                            case .success(let message):
                                                UIAlertController.showAlertWithOk(title: .localized("Success"), message: .localized(message))
                                            case .failure(let finalError):
                                                UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized(finalError.localizedDescription))
                                            }
                                        }
                                    }
                                }
                            )
                        } else {
                            UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized(importError.localizedDescription))
                        }
                    }
                }
            }
        }
    }
    
    
    private func sanitizeFileName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:?*<>|\"\\")
        return name.components(separatedBy: invalidCharacters).joined()
    }
    
    func importFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            var failureCount = 0
            
            for url in urls {
                do {
                    guard fileManager.fileExists(atPath: url.path) else {
                        throw NSError(domain: "FileImportError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Source file not accessible: \(url.lastPathComponent)"])
                    }
                    
                    let destinationURL = self.currentDirectory.appendingPathComponent(url.lastPathComponent)
                    let finalDestinationURL = self.generateUniqueFileName(for: destinationURL)
                    
                    try self.importSingleItem(from: url, to: finalDestinationURL)
                } catch {
                    failureCount += 1
                }
            }
            
            DispatchQueue.main.async {
                if failureCount > 0 {
                    UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Failed to import \(failureCount) file\(failureCount == 1 ? "" : "s")"))
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    self.loadFiles()
                }
            }
        }
    }
    
    private func importSingleItem(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw NSError(
                domain: "FileImportError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Source does not exist: \(sourceURL.path)"]
            )
        }
        
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw NSError(
                domain: "FileImportError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to copy file: \(error.localizedDescription)"]
            )
        }
    }
    

    
    private func generateUniqueFileName(for url: URL) -> URL {
        let fileManager = FileManager.default
        
        if !fileManager.fileExists(atPath: url.path) {
            return url
        }
        
        let directory = url.deletingLastPathComponent()
        let filename = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        
        var counter = 1
        var newURL: URL
        
        repeat {
            let newFilename = pathExtension.isEmpty 
                ? "\(filename) (\(counter))"
                : "\(filename) (\(counter)).\(pathExtension)"
            newURL = directory.appendingPathComponent(newFilename)
            counter += 1
        } while fileManager.fileExists(atPath: newURL.path) && counter < 1000 // Safety limit
        
        return newURL
    }
    
    func extractArchive(_ file: FileItem) {
        guard file.isArchive else { return }
        
        NotificationCenter.default.post(name: NSNotification.Name("ExtractionStarted"), object: nil)
        
        ExtractionService.extractArchive(file, to: currentDirectory) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    NotificationCenter.default.post(name: NSNotification.Name("ExtractionCompleted"), object: nil)
                    
                    withAnimation {
                        self?.loadFiles()
                    }
                    
                    UIAlertController.showAlertWithOk(title: .localized("Success"), message: .localized("File extracted successfully"))
                    
                case .failure(let error):
                    NotificationCenter.default.post(name: NSNotification.Name("ExtractionFailed"), object: nil)
                    UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Error extracting archive: \(error.localizedDescription)"))
                }
            }
        }
    }
    
    func packageAppAsIPA(_ file: FileItem) {
        guard file.isAppDirectory else { return }
        
        NotificationCenter.default.post(name: NSNotification.Name("ExtractionStarted"), object: nil)
        
        ExtractionService.packageAppAsIPA(file, to: currentDirectory) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let ipaFileName):
                    NotificationCenter.default.post(name: NSNotification.Name("ExtractionCompleted"), object: nil)
                    self?.loadFiles()
                    UIAlertController.showAlertWithOk(title: .localized("Success"), message: .localized("Successfully packaged \(file.name) as \(ipaFileName)"))
                    
                case .failure(let error):
                    NotificationCenter.default.post(name: NSNotification.Name("ExtractionFailed"), object: nil)
                    UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Failed to package IPA: \(error.localizedDescription)"))
                }
            }
        }
    }
    
} 
