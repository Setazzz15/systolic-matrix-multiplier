import numpy as np
import torch as t 
import matplotlib.pyplot as plt
from models import * 
import torch.optim as optim
import time


def unpickle(file):
    import pickle
    with open(file, 'rb') as fo:
        dict = pickle.load(fo, encoding='bytes')
    return dict


def validation_error(model, ims, labels):

    with t.no_grad():
        predictions = model(ims)
        predictions = t.argmax(predictions, dim=1)

        correct = (predictions == labels)
        
        return 1.0 - t.mean(correct.float())

if __name__ == "__main__":   
    # =================================================================================
    # Dataset loading
    # =================================================================================

    all_ims = []
    all_labels = []

    for i in range(1, 6):

        data = unpickle(f"./Data/cifar-10-batches-py/data_batch_{i}")
        ims = data[b'data'].reshape(10000, 3, 32, 32)
        labels = np.array(data[b'labels'])

        all_ims.append(ims)
        all_labels.append(labels)
    
    test_data = unpickle("./Data/cifar-10-batches-py/test_batch")
    test_ims = test_data[b'data'].reshape(10000, 3, 32, 32)
    test_labels = np.array(test_data[b'labels'])

    ims = np.concatenate(all_ims, axis=0)
    labels = np.concatenate(all_labels, axis=0)

    print(ims.shape)
    print(labels.shape)
    print(test_ims.shape)
    print(test_labels.shape)

    # Dataset shuffling

    indices = np.random.permutation(np.arange(ims.shape[0]))
    ims = ims[indices]
    labels = labels[indices]

    # normalization and conversion to pytorch format 

    ims = ims.transpose(0, 2, 3, 1)
    test_ims = test_ims.transpose(0, 2, 3, 1)

    ims = ims.astype(np.float32) / 255.0
    test_ims = test_ims.astype(np.float32) / 255.0

    labels = t.from_numpy(labels)
    ims = t.from_numpy(ims)
     

    test_ims = t.from_numpy(test_ims).transpose(1,3)
    test_labels = t.from_numpy(test_labels)

    # =================================================================================
    # Training Loop
    # =================================================================================

    n_epoch = 20
    n_data = ims.shape[0]
    batch_size = 64
    n_iter = (n_data * n_epoch) // batch_size

    model = Net()

    lr = 1e-2
    momentum = 0.9


    optimizer = optim.SGD(model.parameters(), lr = lr, momentum = momentum)

    loss_fn = nn.CrossEntropyLoss()
    start = time.time()
    
    training_losses = []
    test_errors = []


    for i in range(n_iter):

        # sample data points 
        indices = np.random.permutation(np.arange(n_data))[:batch_size]

        data_x = ims[indices].transpose(1,3)
        data_y = labels[indices]

        predictions = model(data_x)
        
        loss = loss_fn(predictions, data_y)

    
        if i % 100 == 0:

            test_error = validation_error(model, test_ims, test_labels)

            training_losses.append(loss.item())
            test_errors.append(test_error.item())

            stop = time.time()

            print(f"iter: {i}/{n_iter} loss: {loss.item()}, test_error: {test_error.item()} time diff: {stop - start}")

            start = time.time()
    

        if i == 5000:
            #decrease lr by 10 in optimizer
            for param_group in optimizer.param_groups:
                param_group['lr'] *= 0.1

        if i == 10000:
            #decrease lr by 10 in optimizer
            for param_group in optimizer.param_groups:
                param_group['lr'] *= 0.1
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()

    # save model dict to file
    t.save(model.state_dict(), 'model.pt')

    
    #plot trainign loss and test error in 2 subplots:

    plt.figure(figsize=(10,5))
    plt.subplot(1,2,1)
    plt.plot(training_losses)
    plt.xlabel('Iteration')
    plt.ylabel('Training Loss')
    plt.title('Training Loss')

    plt.subplot(1,2,2)
    plt.plot(test_errors)
    plt.xlabel('Iteration')
    plt.ylabel('Test Error')
    plt.title('Test Error')

    plt.tight_layout()
    plt.show()